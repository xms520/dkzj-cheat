//
//  DKZJ.m — 弹壳战机 1.1.7 (com.survivor.acecn) 悬浮助手 v3.0
//  ═══════════════════════════════════════════════════════════════════════
//  引擎: Unity 2022.3.62f2 IL2CPP + HybridCLR 热更 (HotFix.dll / HotFixBattle.dll)
//  metadata v31 全量解析实证 (30214 类型, 逻辑全在热更层, 无混淆)
//
//  功能 (7 项, 全部走 il2cpp 运行时反射, 零 __TEXT patch):
//    ① 怪物自杀/秒杀   EntityManager.GetEntityValues → EntityCharacter.SetHp(0)+OnDeath
//                      优先 EntityManager.EnemyCommitSuicide(entity, reason)
//    ② 无敌            EntityCharacter.AddAbsoluteInvincibility() + set_CurrentHp
//    ③ 一键通关        BattleManager.OnMissionClear() / SetWinPlayerId+CreateBattleEndEvent
//    ④ 游戏加速        WorldContext.gameSpeed 直写 (sim 逻辑倍速, Q16.16 定点)
//    ⑤ 免广告          ADModuleMgr.CheckAndPlayVideo methodPointer 热替换(直回调)
//                      + AdData.GetLeftAdCount 无限次
//    ⑥ 局内经验增加    BattleData.AddUserExp(n) / BattleManager.AddExpAndGold()
//    ⑦ 局内金币增加    BattleData.AddDropGold(n) / AddWaveGold(n)
//
//  调用链 (全走方法调用, 不硬编码偏移):
//    BattleGame.get_World() → WorldBattle
//      → get_LogicWorld() → BattleLogicWorld → <_worldContext 字段>
//        → BattleWorldContext
//           .get_Entity()      → EntityManager
//           .get_BattleMgr()   → BattleManager
//           .get_BattleData()  → BattleData
//
//  铁律: 类解析在后台线程(il2cpp_thread_attach), 功能执行在主线程 tick
//        SIGSEGV 守卫 | 只对目标包注入 | 帧同步游戏仅单机 PvE
//  ⚠️ 联机会上行命令到服务器, 勿在联机模式开启
//  ═══════════════════════════════════════════════════════════════════════

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <os/proc.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdarg.h>
#include <math.h>
#include <setjmp.h>
#include <signal.h>

// ───────────────────── 日志 ─────────────────────
static void L(const char *fmt, ...) {
    char msg[768];
    va_list ap; va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = paths.firstObject;
    if (doc) {
        FILE *f = fopen([doc stringByAppendingPathComponent:@"dkzj3.log"].fileSystemRepresentation, "a");
        if (f) { fprintf(f, "%s\n", msg); fclose(f); }
    }
    NSLog(@"[DKZJ3] %s", msg);
}

// ───────────────────── 功能开关 ─────────────────────
static BOOL  g_killOn   = NO;    // ① 秒杀
static BOOL  g_invOn    = NO;    // ② 无敌
static BOOL  g_speedOn  = NO;    // ④ 加速
static BOOL  g_noAdOn   = NO;    // ⑤ 免广告
static BOOL  g_speedWasOn = NO;
static float g_speedMult = 2.0f;
static int   g_expValue  = 1000;   // ⑥ 单次经验
static int   g_goldValue = 1000;   // ⑦ 单次金币
static BOOL  g_inBattle = NO;

static UIButton *g_ball = nil;
static UIView   *g_panel = nil;
static UIPanGestureRecognizer *g_panelPan = nil;
static UILabel  *g_statusSub = nil;
static UILabel  *g_expVal = nil, *g_goldVal = nil, *g_spdVal = nil;

// ───────────────────── SIGSEGV 安全网 ─────────────────────
static volatile sig_atomic_t g_guardActive = 0;
static sigjmp_buf g_guardEnv;
static void dk_segv_handler(int sig) {
    if (g_guardActive) { g_guardActive = 0; g_guardDepth = 0; siglongjmp(g_guardEnv, 1); }
    signal(sig, SIG_DFL);
    raise(sig);
}
static int g_guardDepth = 0;
static void dk_guard_install(void) {
    struct sigaction sa; memset(&sa, 0, sizeof(sa));
    sa.sa_handler = dk_segv_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
}
// 嵌套安全: 用深度计数, 内层退出不解除外层保护
#define DK_GUARD_BEGIN() (g_guardDepth++, g_guardActive = 1, sigsetjmp(g_guardEnv, 1))
#define DK_GUARD_END()   do { if (g_guardDepth > 0) g_guardDepth--; if (g_guardDepth == 0) g_guardActive = 0; } while (0)

// ───────────────────── Unity 基址 ─────────────────────
static uint64_t g_unityBase = 0;
static uint64_t g_textSize  = 0;
static int      g_slide     = 0;

static const struct mach_header_64 *dk_unity_header(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "UnityFramework")) {
            const struct mach_header *h = _dyld_get_image_header(i);
            if (h && h->magic == MH_MAGIC_64) g_slide = _dyld_get_image_vmaddr_slide(i);
            return (const struct mach_header_64 *)h;
        }
    }
    return NULL;
}

static uint64_t find_unity_base(void) {
    const struct mach_header_64 *mh = dk_unity_header();
    if (!mh) return 0;
    g_unityBase = (uint64_t)mh;
    const uint8_t *p = (const uint8_t *)mh + sizeof(struct mach_header_64);
    for (uint32_t c = 0; c < mh->ncmds; c++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)p;
            if (strcmp(sg->segname, "__TEXT") == 0) { g_textSize = sg->vmsize; break; }
        }
        p += lc->cmdsize;
    }
    return g_unityBase;
}

// ───────────────────── 内存 Mach-O 符号表 (CJCS 实证方案) ─────────────────────
// UnityFramework 的 il2cpp_* 在 1.1.7 里同时在 EXPORTS_TRIE 中(dlsym 可用),
// 但 LC_SYMTAB 的 nsyms/symoff 字段被加固改写 → 静态枚举不可靠。
// 双路: ① dlsym(RTLD_DEFAULT) ② LC_SYMTAB nlist 全表扫描 (含 __LINKEDIT 换算)
typedef struct { const char *name; uintptr_t addr; } dk_sym_t;
static dk_sym_t *g_syms = NULL;
static uint32_t  g_symCount = 0;
static int32_t  *g_hashBucket = NULL;
static uint32_t  g_hashMask = 0;
static int       g_symsReady = 0;

static uint32_t dk_hash(const char *s) {
    uint32_t h = 5381;
    while (*s) h = ((h << 5) + h) + (unsigned char)(*s++);
    return h;
}

static void dk_syms_load(void) {
    if (g_symsReady) return;
    g_symsReady = 1;
    const struct mach_header_64 *mh = dk_unity_header();
    if (!mh) { L("sym: UnityFramework 未找到"); return; }
    const struct load_command *lc = (const struct load_command *)((const char *)mh + sizeof(struct mach_header_64));
    const struct symtab_command *st = NULL;
    const struct segment_command_64 *le = NULL;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SYMTAB) st = (const struct symtab_command *)lc;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            if (!strcmp(sg->segname, "__LINKEDIT")) le = sg;
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    if (!st || !le) { L("sym: LC_SYMTAB/__LINKEDIT 缺失"); return; }
    // vmaddr-fileoff 差值 (1.1.7: __LINKEDIT vmaddr 0xAF8A000 fileoff 0xAF8A000 → 差 0)
    uintptr_t le_delta = (uintptr_t)(le->vmaddr - le->fileoff);
    // nlist 表: 文件偏移 st->symoff → 运行时 = mh + le_delta + slide + symoff
    //   (mh 已含 slide, 不能再加; CJCS 的坑: mh 指针来自 dyld → 已滑动)
    const struct nlist_64 *nl  = (const struct nlist_64 *)((uintptr_t)mh + le_delta + st->symoff);
    const char            *str = (const char *)((uintptr_t)mh + le_delta + st->stroff);
    uint32_t nsyms = st->nsyms;
    // 加固可能改写 nsyms → 用 (stroff - symoff)/16 与 nsyms 取大值, 上限保护
    if (st->stroff > st->symoff) {
        uint32_t byGap = (st->stroff - st->symoff) / 16;
        if (byGap < 4000000) nsyms = (byGap > nsyms) ? byGap : nsyms;
    }
    if (nsyms > 4000000) nsyms = 4000000;
    g_syms = (dk_sym_t *)calloc(nsyms > 0 ? nsyms : 1, sizeof(dk_sym_t));
    if (!g_syms) { L("sym: calloc 失败"); return; }
    // 两遍扫描: 先计数再精确分配 (避免大块 malloc 被杀)
    uint32_t kept = 0;
    for (uint32_t i = 0; i < nsyms; i++) {
        uint32_t sx = nl[i].n_un.n_strx;
        if (!nl[i].n_value || sx == 0 || sx >= st->strsize) continue;
        const char *nm = str + sx;
        if (nm[0] != '_') continue;
        if (!strncmp(nm, "_il2cpp_", 8) || !strncmp(nm, "_mono_", 6) || !strncmp(nm, "_lua", 4)) {
            g_syms[kept].name = strdup(nm);
            g_syms[kept].addr = (uintptr_t)(nl[i].n_value + g_slide);
            kept++;
            if (kept >= nsyms) break;
        }
    }
    g_symCount = kept;
    L("sym: nlist scan nsyms=%u kept=%u (slide=%d)", nsyms, kept, g_slide);
    if (kept == 0) return;
    uint32_t cap = 1; while (cap < kept * 2) cap <<= 1;
    g_hashBucket = (int32_t *)malloc(cap * sizeof(int32_t));
    if (!g_hashBucket) return;
    for (uint32_t i = 0; i < cap; i++) g_hashBucket[i] = -1;
    g_hashMask = cap - 1;
    for (uint32_t i = 0; i < kept; i++) {
        uint32_t b = dk_hash(g_syms[i].name) & g_hashMask;
        while (g_hashBucket[b] != -1) b = (b + 1) & g_hashMask;
        g_hashBucket[b] = (int32_t)i;
    }
    L("sym: hash ready cap=%u", cap);
}

static void *dk_sym_find(const char *name) {
    // ① dlsym 优先 (1.1.7 EXPORTS_TRIE 实证含 241 个 il2cpp 符号)
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) return p;
    p = dlsym(RTLD_DEFAULT, name + 1);   // 去掉前导下划线再试
    if (p) return p;
    // ② 内存符号表
    if (g_hashBucket) {
        uint32_t b = dk_hash(name) & g_hashMask;
        while (g_hashBucket[b] != -1) {
            if (!strcmp(g_syms[g_hashBucket[b]].name, name))
                return (void *)g_syms[g_hashBucket[b]].addr;
            b = (b + 1) & g_hashMask;
        }
    }
    return NULL;
}

static int dk_ptr_executable(uintptr_t a) {
    if (!a) return 0;
    uintptr_t lo = g_unityBase, hi = g_unityBase + g_textSize;
    return (a >= lo && a < hi) ? 1 : 0;
}
