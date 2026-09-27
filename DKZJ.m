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

// ───────────────────── il2cpp C API ─────────────────────
typedef void* Il2CppDomain;
typedef void* Il2CppImage;
typedef void* Il2CppClass;
typedef void* Il2CppMethodInfo;
typedef void* Il2CppFieldInfo;
typedef void* Il2CppObject;
typedef void* Il2CppString;

typedef struct {
    Il2CppDomain      (*domain_get)(void);
    void*             (*domain_get_assemblies)(Il2CppDomain, size_t *);
    Il2CppImage       (*assembly_get_image)(void *);
    Il2CppClass*      (*class_from_name)(Il2CppImage, const char *, const char *);
    Il2CppMethodInfo* (*class_get_method_from_name)(Il2CppClass *, const char *, int);
    Il2CppMethodInfo* (*class_get_methods)(Il2CppClass *, void **);
    Il2CppFieldInfo*  (*class_get_field_from_name)(Il2CppClass *, const char *);
    Il2CppFieldInfo*  (*class_get_fields)(Il2CppClass *, void **);
    Il2CppClass*      (*class_get_parent)(Il2CppClass *);
    const char*       (*class_get_name)(Il2CppClass *);
    const char*       (*class_get_namespace)(Il2CppClass *);
    const char*       (*method_get_name)(Il2CppMethodInfo *);
    int               (*method_get_param_count)(Il2CppMethodInfo *);
    const char*       (*field_get_name)(Il2CppFieldInfo *);
    size_t            (*field_get_offset)(Il2CppFieldInfo *);
    void              (*field_get_value)(Il2CppObject *, Il2CppFieldInfo *, void *);
    void              (*field_set_value)(Il2CppObject *, Il2CppFieldInfo *, void *);
    void              (*field_static_get_value)(Il2CppFieldInfo *, void *);
    void              (*field_static_set_value)(Il2CppFieldInfo *, void *);
    Il2CppObject*     (*runtime_invoke)(Il2CppMethodInfo *, void *, void **, void **);
    Il2CppString*     (*string_new)(const char *);
    Il2CppObject*     (*object_new)(Il2CppClass *);
    void*             (*thread_attach)(Il2CppDomain);
    void*             (*thread_current)(void);
    void              (*gc_disable)(void);
    Il2CppClass*      (*object_get_class)(Il2CppObject *);
    int               (*class_is_assignable_from)(Il2CppClass *, Il2CppClass *);
    Il2CppObject*     (*value_box)(Il2CppClass *, void *);
    void              (*class_init)(Il2CppClass *);
    const char*       (*image_get_name)(Il2CppImage);
    size_t            (*image_get_class_count)(Il2CppImage);
    Il2CppClass*      (*image_get_class)(Il2CppImage, size_t);
} dk_il2cpp_t;

static dk_il2cpp_t I;
static BOOL ic_ready = NO;

static BOOL ic_init(void) {
    if (ic_ready) return YES;
    if (!g_unityBase) return NO;
    memset(&I, 0, sizeof(I));
    I.domain_get                  = (void*)dk_sym_find("_il2cpp_domain_get");
    I.domain_get_assemblies       = (void*)dk_sym_find("_il2cpp_domain_get_assemblies");
    I.assembly_get_image          = (void*)dk_sym_find("_il2cpp_assembly_get_image");
    I.class_from_name             = (void*)dk_sym_find("_il2cpp_class_from_name");
    I.class_get_method_from_name  = (void*)dk_sym_find("_il2cpp_class_get_method_from_name");
    I.class_get_methods           = (void*)dk_sym_find("_il2cpp_class_get_methods");
    I.class_get_field_from_name   = (void*)dk_sym_find("_il2cpp_class_get_field_from_name");
    I.class_get_fields            = (void*)dk_sym_find("_il2cpp_class_get_fields");
    I.class_get_parent            = (void*)dk_sym_find("_il2cpp_class_get_parent");
    I.class_get_name              = (void*)dk_sym_find("_il2cpp_class_get_name");
    I.class_get_namespace         = (void*)dk_sym_find("_il2cpp_class_get_namespace");
    I.method_get_name             = (void*)dk_sym_find("_il2cpp_method_get_name");
    I.method_get_param_count      = (void*)dk_sym_find("_il2cpp_method_get_param_count");
    I.field_get_name              = (void*)dk_sym_find("_il2cpp_field_get_name");
    I.field_get_offset            = (void*)dk_sym_find("_il2cpp_field_get_offset");
    I.field_get_value             = (void*)dk_sym_find("_il2cpp_field_get_value");
    I.field_set_value             = (void*)dk_sym_find("_il2cpp_field_set_value");
    I.field_static_get_value      = (void*)dk_sym_find("_il2cpp_field_static_get_value");
    I.field_static_set_value      = (void*)dk_sym_find("_il2cpp_field_static_set_value");
    I.runtime_invoke              = (void*)dk_sym_find("_il2cpp_runtime_invoke");
    I.string_new                  = (void*)dk_sym_find("_il2cpp_string_new");
    I.object_new                  = (void*)dk_sym_find("_il2cpp_object_new");
    I.thread_attach               = (void*)dk_sym_find("_il2cpp_thread_attach");
    I.thread_current              = (void*)dk_sym_find("_il2cpp_thread_current");
    I.gc_disable                  = (void*)dk_sym_find("_il2cpp_gc_disable");
    I.object_get_class            = (void*)dk_sym_find("_il2cpp_object_get_class");
    I.class_is_assignable_from    = (void*)dk_sym_find("_il2cpp_class_is_assignable_from");
    I.value_box                   = (void*)dk_sym_find("_il2cpp_value_box");
    I.class_init                  = (void*)dk_sym_find("_il2cpp_runtime_class_init");
    I.image_get_name              = (void*)dk_sym_find("_il2cpp_image_get_name");
    I.image_get_class_count       = (void*)dk_sym_find("_il2cpp_image_get_class_count");
    I.image_get_class             = (void*)dk_sym_find("_il2cpp_image_get_class");
    int miss = 0;
    struct { const char *n; void *p; } req[] = {
        {"domain_get", I.domain_get}, {"domain_get_assemblies", I.domain_get_assemblies},
        {"assembly_get_image", I.assembly_get_image}, {"class_from_name", I.class_from_name},
        {"class_get_method_from_name", I.class_get_method_from_name},
        {"class_get_field_from_name", I.class_get_field_from_name},
        {"field_get_offset", I.field_get_offset}, {"runtime_invoke", I.runtime_invoke},
        {"object_get_class", I.object_get_class},
    };
    for (size_t i = 0; i < sizeof(req)/sizeof(req[0]); i++) {
        uintptr_t a = (uintptr_t)req[i].p;
        if (!a) { miss++; L("ic: MISSING %s", req[i].n); }
        else if (!dk_ptr_executable(a)) L("ic: OUT-OF-RANGE %s = %p", req[i].n, req[i].p);
    }
    if (miss) { L("ic: %d 必需 API 缺失 → 禁用", miss); return NO; }
    ic_ready = YES;
    L("ic ✓ il2cpp C API 就绪 (domain_get=%p invoke=%p)", I.domain_get, I.runtime_invoke);
    return YES;
}

static void ic_ensure_thread(void) {
    if (!ic_ready || !I.domain_get) return;
    Il2CppDomain dom = I.domain_get();
    if (!dom) return;
    if (I.thread_current && !I.thread_current() && I.thread_attach) I.thread_attach(dom);
}

static Il2CppImage ic_find_image(const char *want) {
    if (!ic_ready) return NULL;
    Il2CppDomain dom = I.domain_get();
    if (!dom) return NULL;
    size_t n = 0;
    void **asms = (void **)I.domain_get_assemblies(dom, &n);
    if (!asms) return NULL;
    for (size_t i = 0; i < n; i++) {
        if (!asms[i]) continue;
        Il2CppImage img = I.assembly_get_image(asms[i]);
        if (!img) continue;
        const char *nm = I.image_get_name ? I.image_get_name(img) : NULL;
        if (nm && !strcmp(nm, want)) return img;
    }
    return NULL;
}

// 方法调用包装: 参数按 il2cpp_runtime_invoke 约定 (值类型传指针, 引用类型传对象)
static Il2CppObject *ic_call(void *mi, void *obj, void **args) {
    if (!mi || !I.runtime_invoke) return NULL;
    void *exc = NULL;
    return I.runtime_invoke(mi, obj, args, &exc);   // exc 忽略(异常时返回 NULL)
}

static int ic_call_i32(void *mi, void *obj, int32_t arg) {
    void *args[1] = { &arg };
    Il2CppObject *r = ic_call(mi, obj, args);
    return r ? *(int32_t *)((uint8_t *)r + 0x10) : 0;   // 装箱 int32 → 值在 +0x10
}

static int64_t ic_call_i64(void *mi, void *obj, int64_t arg) {
    void *args[1] = { &arg };
    Il2CppObject *r = ic_call(mi, obj, args);
    return r ? *(int64_t *)((uint8_t *)r + 0x10) : 0;
}

static float ic_call_f(void *mi, void *obj, float arg) {
    void *args[1] = { &arg };
    Il2CppObject *r = ic_call(mi, obj, args);
    return r ? *(float *)((uint8_t *)r + 0x10) : 0.0f;
}

// List<T> / 数组 布局 (Il2CppArray: [klass 0x00][monitor 0x08][bounds 0x10][max_length 0x18][data 0x20])
// Il2CppArray: [klass 0x00][monitor 0x08][bounds 0x10][max_length 0x18][data 0x20]
static int32_t arr_len(void *arr)  { return arr ? *(int32_t *)((uint8_t *)arr + 0x18) : 0; }
static void    *arr_at(void *arr, int i) {
    if (!arr || i < 0) return NULL;
    return *(void **)((uint8_t *)arr + 0x20 + 8 * i);
}
// List<T>: <_items>@0x10 <_size>@0x18
static void    *list_items(void *lst) { return *(void **)((uint8_t *)lst + 0x10); }
static int32_t  list_size(void *lst)  { return *(int32_t *)((uint8_t *)lst + 0x18); }
static void    *list_at(void *lst, int i) {
    void *items = list_items(lst);
    if (!items) return NULL;
    return *(void **)((uint8_t *)items + 0x20 + 8 * i);
}

// ───────────────────── 类/方法解析 (后台线程, 两阶段) ─────────────────────
static Il2CppImage g_imgHF  = NULL;   // HotFix.dll (WorldBattle/BattleGame/Game/ADModuleMgr...)
static Il2CppImage g_imgHFB = NULL;   // HotFixBattle.dll (BattleLogic.* 战斗核心)
static Il2CppImage g_imgCOR = NULL;   // mscorlib.dll

// 类
static Il2CppClass *k_BattleGame, *k_WorldBattle, *k_BLW, *k_Ctx;
static Il2CppClass *k_EM, *k_Char, *k_Hero, *k_TDD, *k_BattleMgr, *k_BattleData;
static Il2CppClass *k_ADMgr, *k_AdData, *k_I64;
static Il2CppClass *k_Game, *k_GameMgr;

// 方法 (BattleGame/WorldBattle)
static void *m_BG_getWorld;        // BattleGame.get_World  (static)
static void *m_WB_getLogicWorld;   // WorldBattle.get_LogicWorld (instance)
static void *m_WB_StopTime, *m_WB_ResetTime, *m_WB_SetLevel, *m_WB_SetPlayerAttackAndCurHp;
// 上下文访问器 (instance)
static void *m_Ctx_getEntity, *m_Ctx_getBattleMgr, *m_Ctx_getBattleData, *m_Ctx_getBattleFrame;
// EntityManager
static void *m_EM_GetEntityValues, *m_EM_GetAllPlayer, *m_EM_GetPlayer;
// EntityCharacter
static void *m_Char_SetHp, *m_Char_GetHp, *m_Char_OnDeath, *m_Char_UpdateHp;
static void *m_Char_getIsDead, *m_Char_getCamp, *m_Char_Suicide;
static void *m_Char_AddAbsInv, *m_Char_RemoveAbsInv, *m_Char_getIsInvincible;
static void *m_Char_AddStatus, *m_Char_RemoveStatus;
static void *m_Char_getCurrentHp, *m_Char_setCurrentHp;
static void *m_Char_getStatusMgr;
// BattleManager
static void *m_BM_AddExpAndGold, *m_BM_OnMissionClear, *m_BM_OnChapterEnd;
static void *m_BM_CreateBattleEndEvent, *m_BM_GetCurWave, *m_BM_AddExBattleAttr;
static void *m_BM_SetPlayerLevelAndExp, *m_BM_GetPlayerLevelAndExp;
// BattleData
static void *m_BD_AddUserExp, *m_BD_AddDropGold, *m_BD_AddWaveGold, *m_BD_AddDiamond;
static void *m_BD_getGold, *m_BD_setGold, *m_BD_getPlayerExp;
// ADModuleMgr / AdData
static void *m_AD_CheckAndPlayVideo, *m_AD_TrackADReward, *m_AD_OnShow;
static void *k_AD_onCloseField;
static void *m_AdData_GetLeftAdCount;
// CharacterStatusManager
static void *m_CSM_AddCharacterStatus;
// Game / GameManager (加速)
static void *m_GM_SetTimeScale, *m_Game_SetTimeScale;
static void *m_Game_getCoreMgr;
// GorillaAd.Runtime (免广告)
static void *m_Ad_Show0 = NULL;     // LocalRewardedVideoAd.Show() 无参
static void *m_AdMan_Show7 = NULL;  // GorillaAdManager.Show(...) 7 参
static Il2CppClass *k_Ad_Local = NULL;

static int32_t off_CurLogicWorld = -1;   // WorldBattle.CurLogicWorld (static field)
static int32_t off_BLW_worldCtx   = -1;  // BattleLogicWorld._worldContext
static int32_t off_Ctx_gameSpeed  = -1;  // BattleWorldContext.gameSpeed
static int32_t off_World_timeScale= -1;  // WorldBattle._curTimeScale
static int32_t off_AD_onClose     = -1;  // ADModuleMgr._onClose

static BOOL g_parsed = NO;
static void *g_worldCache = NULL;        // WorldBattle 实例缓存

static int32_t foff(Il2CppClass *k, const char *name) {
    if (!k || !I.class_get_field_from_name) return -1;
    Il2CppFieldInfo *f = I.class_get_field_from_name(k, name);
    if (!f || !I.field_get_offset) return -1;
    return (int32_t)I.field_get_offset(f);
}

static void *ic_class(const char *img, const char *ns, const char *name) {
    Il2CppImage im = NULL;
    if (!strcmp(img, "HotFix"))        im = g_imgHF;
    else if (!strcmp(img, "HotFixBattle")) im = g_imgHFB;
    else if (!strcmp(img, "mscorlib")) im = g_imgCOR;
    if (!im) return NULL;
    return I.class_from_name(im, ns, name);
}

// ───────────────────── 阶段A: 后台线程解析 ─────────────────────
static BOOL resolve_try(void) {
    if (!ic_ready) return NO;
    if (!g_imgHF)  g_imgHF  = ic_find_image("HotFix.dll");
    if (!g_imgHFB) g_imgHFB = ic_find_image("HotFixBattle.dll");
    if (!g_imgCOR) g_imgCOR = ic_find_image("mscorlib.dll");
    if (!g_imgHF || !g_imgHFB) {
        static int n = 0; if (++n <= 5) L("A: img HotFix=%p HotFixBattle=%p (热更未加载?)", g_imgHF, g_imgHFB);
        return NO;
    }
    k_BattleGame = ic_class("HotFix", "HotFix", "BattleGame");
    k_WorldBattle= ic_class("HotFix", "HotFix", "WorldBattle");
    k_BLW        = ic_class("HotFixBattle", "HotFix.BattleLogic", "BattleLogicWorld");
    k_Ctx        = ic_class("HotFixBattle", "HotFix.BattleLogic", "BattleWorldContext");
    k_EM         = ic_class("HotFixBattle", "HotFix.BattleLogic", "EntityManager");
    k_Char       = ic_class("HotFixBattle", "HotFix.BattleLogic", "EntityCharacter");
    k_Hero       = ic_class("HotFixBattle", "HotFix.BattleLogic", "EntityHero");
    k_TDD        = ic_class("HotFixBattle", "HotFix.BattleLogic", "TakeDamageData");
    k_BattleMgr  = ic_class("HotFixBattle", "HotFix.BattleLogic", "BattleManager");
    k_BattleData = ic_class("HotFixBattle", "HotFix.BattleLogic", "BattleData");
    k_ADMgr      = ic_class("HotFix", "HotFix", "ADModuleMgr");
    k_AdData     = ic_class("HotFix", "HotFix", "AdData");
    k_I64        = ic_class("mscorlib", "System", "Int64");
    k_Game       = ic_class("HotFix", "HotFix", "Game");
    k_GameMgr    = ic_class("HotFix", "HotFix", "GameManager");
    if (!k_BattleGame || !k_WorldBattle || !k_Ctx || !k_Char) {
        static int n2 = 0;
        if (++n2 <= 5) L("A: 类缺失 BG=%p WB=%p CTX=%p Char=%p BLW=%p",
                         k_BattleGame, k_WorldBattle, k_Ctx, k_Char, k_BLW);
        return NO;
    }
    m_BG_getWorld      = I.class_get_method_from_name(k_BattleGame, "get_World", 0);
    m_WB_getLogicWorld = I.class_get_method_from_name(k_WorldBattle, "get_LogicWorld", 0);
    m_WB_StopTime      = I.class_get_method_from_name(k_WorldBattle, "StopTime", 0);
    m_WB_ResetTime     = I.class_get_method_from_name(k_WorldBattle, "ResetTime", 0);
    m_WB_SetLevel      = I.class_get_method_from_name(k_WorldBattle, "SetLevel", 1);

    m_Ctx_getEntity    = k_Ctx ? I.class_get_method_from_name(k_Ctx, "get_Entity", 0) : NULL;
    m_Ctx_getBattleMgr = k_Ctx ? I.class_get_method_from_name(k_Ctx, "get_BattleMgr", 0) : NULL;
    m_Ctx_getBattleData= k_Ctx ? I.class_get_method_from_name(k_Ctx, "get_BattleData", 0) : NULL;

    if (k_EM) {
        m_EM_GetEntityValues = I.class_get_method_from_name(k_EM, "GetEntityValues", 0);
        m_EM_GetAllPlayer    = I.class_get_method_from_name(k_EM, "GetAllPlayer", 0);
        m_EM_GetPlayer       = I.class_get_method_from_name(k_EM, "GetPlayer", 1);
    }
    if (k_Char) {
        m_Char_SetHp         = I.class_get_method_from_name(k_Char, "SetHp", 1);
        m_Char_GetHp         = I.class_get_method_from_name(k_Char, "GetHp", 0);
        m_Char_OnDeath       = I.class_get_method_from_name(k_Char, "OnDeath", 1);
        m_Char_UpdateHp      = I.class_get_method_from_name(k_Char, "UpdateHp", 1);
        m_Char_getIsDead     = I.class_get_method_from_name(k_Char, "get_IsDead", 0);
        m_Char_Suicide       = I.class_get_method_from_name(k_Char, "Suicide", 1);
        m_Char_AddAbsInv     = I.class_get_method_from_name(k_Char, "AddAbsoluteInvincibility", 0);
        m_Char_RemoveAbsInv  = I.class_get_method_from_name(k_Char, "RemoveAbsoluteInvincibility", 0);
        m_Char_getIsInvincible = I.class_get_method_from_name(k_Char, "get_IsInvincible", 0);
        m_Char_AddStatus     = I.class_get_method_from_name(k_Char, "AddCharacterStatus", 1);
        m_Char_RemoveStatus  = I.class_get_method_from_name(k_Char, "RemoveCharacterStatus", 1);
        m_Char_getCurrentHp  = I.class_get_method_from_name(k_Char, "get_CurrentHp", 0);
        m_Char_setCurrentHp  = I.class_get_method_from_name(k_Char, "set_CurrentHp", 1);
    }
    if (k_BattleMgr) {
        m_BM_AddExpAndGold   = I.class_get_method_from_name(k_BattleMgr, "AddExpAndGold", 0);
        m_BM_OnMissionClear  = I.class_get_method_from_name(k_BattleMgr, "OnMissionClear", 0);
        m_BM_OnChapterEnd    = I.class_get_method_from_name(k_BattleMgr, "OnChapterEnd", 0);
        m_BM_GetCurWave      = I.class_get_method_from_name(k_BattleMgr, "GetCurWave", 0);
    }
    if (k_BattleData) {
        m_BD_AddUserExp      = I.class_get_method_from_name(k_BattleData, "AddUserExp", 1);
        m_BD_AddDropGold     = I.class_get_method_from_name(k_BattleData, "AddDropGold", 1);
        m_BD_AddWaveGold     = I.class_get_method_from_name(k_BattleData, "AddWaveGold", 1);
        m_BD_AddDiamond      = I.class_get_method_from_name(k_BattleData, "AddDiamond", 1);
        m_BD_getGold         = I.class_get_method_from_name(k_BattleData, "get_Gold", 0);
        m_BD_setGold         = I.class_get_method_from_name(k_BattleData, "set_Gold", 1);
        m_BD_getPlayerExp    = I.class_get_method_from_name(k_BattleData, "get_PlayerExp", 0);
    }
    if (k_ADMgr) {
        m_AD_CheckAndPlayVideo = I.class_get_method_from_name(k_ADMgr, "CheckAndPlayVideo", 2);
        m_AD_TrackADReward     = I.class_get_method_from_name(k_ADMgr, "TrackADReward", 5);
        m_AD_OnShow            = I.class_get_method_from_name(k_ADMgr, "OnShow", 0);
    }
    if (k_AdData) {
        m_AdData_GetLeftAdCount = I.class_get_method_from_name(k_AdData, "GetLeftAdCount", 1);
    }
    if (k_GameMgr) m_GM_SetTimeScale   = I.class_get_method_from_name(k_GameMgr, "SetTimeScale", 1);
    if (k_Game)    m_Game_SetTimeScale = I.class_get_method_from_name(k_Game, "SetTimeScale", 1);
    // GorillaAd: LocalRewardedVideoAd.Show() 无参 (绕过 SDK, 直接发奖)
    Il2CppImage imAd = ic_find_image("GorillaAd.Runtime.dll");
    if (imAd) {
        k_Ad_Local = I.class_from_name(imAd, "GorillaAd.Runtime", "LocalRewardedVideoAd");
        if (k_Ad_Local) {
            m_Ad_Show0 = I.class_get_method_from_name(k_Ad_Local, "Show", 0);
        }
        Il2CppClass *kAdMan = I.class_from_name(imAd, "GorillaAd.Runtime", "GorillaAdManager");
        if (kAdMan) {
            m_AdMan_Show7 = I.class_get_method_from_name(kAdMan, "Show", 7);
            if (!m_AdMan_Show7) m_AdMan_Show7 = I.class_get_method_from_name(kAdMan, "Show", 8);
        }
        L("A: GorillaAd LocalRewardedVideoAd=%p Show0=%p AdManager.ShowN=%p",
          k_Ad_Local, m_Ad_Show0, m_AdMan_Show7);
    } else {
        L("A: GorillaAd.Runtime.dll image 未找到");
    }
    // 偏移
    off_CurLogicWorld = foff(k_WorldBattle, "CurLogicWorld");
    off_BLW_worldCtx  = foff(k_BLW, "_worldContext");
    off_Ctx_gameSpeed = foff(k_Ctx, "gameSpeed");
    off_World_timeScale = foff(k_WorldBattle, "_curTimeScale");
    off_AD_onClose    = foff(k_ADMgr, "_onClose");
    k_AD_onCloseField = (k_ADMgr && I.class_get_field_from_name)
                      ? I.class_get_field_from_name(k_ADMgr, "_onClose") : NULL;

    if (!m_BG_getWorld && !off_CurLogicWorld) {
        static int n3 = 0; if (++n3 <= 3) L("A: 入口缺失 getWorld=%p CurLogicWorld=0x%x",
                                            m_BG_getWorld, off_CurLogicWorld);
        return NO;
    }
    g_parsed = YES;
    L("A ✓ 解析完成 | getWorld=%p logicWorld=%p ctx@0x%x spd@0x%x tscale@0x%x",
      m_BG_getWorld, m_WB_getLogicWorld, off_BLW_worldCtx, off_Ctx_gameSpeed, off_World_timeScale);
    L("   Char: SetHp=%p OnDeath=%p IsDead=%p AbsInv=%p AddStatus=%p CurHp=%p/%p",
      m_Char_SetHp, m_Char_OnDeath, m_Char_getIsDead, m_Char_AddAbsInv, m_Char_AddStatus,
      m_Char_getCurrentHp, m_Char_setCurrentHp);
    L("   BM: AddExpAndGold=%p OnMissionClear=%p | BD: AddUserExp=%p AddDropGold=%p AddWaveGold=%p",
      m_BM_AddExpAndGold, m_BM_OnMissionClear, m_BD_AddUserExp, m_BD_AddDropGold, m_BD_AddWaveGold);
    L("   AD: CheckAndPlayVideo=%p onClose@0x%x leftAd=%p", m_AD_CheckAndPlayVideo, off_AD_onClose, m_AdData_GetLeftAdCount);
    return YES;
}


// ───────────────────── 扩展 il2cpp API (类型对象/虚调用) ─────────────────────
// 追加到 dk_il2cpp_t 的能力（用独立函数指针，避免改动结构体定义）
typedef void* (*ic_class_get_type_fn)(Il2CppClass *);
typedef void* (*ic_type_get_object_fn)(void *);
typedef void* (*ic_object_new_fn)(Il2CppClass *);
typedef void* (*ic_class_get_static_field_data_fn)(Il2CppClass *);

static ic_class_get_type_fn            p_class_get_type;
static ic_type_get_object_fn           p_type_get_object;
static ic_class_get_static_field_data_fn p_static_field_data;

static void ic_init_ext(void) {
    p_class_get_type      = (ic_class_get_type_fn)dk_sym_find("_il2cpp_class_get_type");
    p_type_get_object     = (ic_type_get_object_fn)dk_sym_find("_il2cpp_type_get_object");
    p_static_field_data   = (ic_class_get_static_field_data_fn)dk_sym_find("_il2cpp_class_get_static_field_data");
    L("ic-ext: class_get_type=%p type_get_object=%p static_field_data=%p",
      p_class_get_type, p_type_get_object, p_static_field_data);
}

// 把 Il2CppClass 转成 System.Type 对象 (FindObjectOfType 需要)
static void *ic_type_of(Il2CppClass *k) {
    if (!k || !p_class_get_type || !p_type_get_object) return NULL;
    void *t = p_class_get_type(k);
    return t ? p_type_get_object(t) : NULL;
}

// ───────────────────── 虚调用: 按【运行时实际类】解析方法 ─────────────────────
// ⚠️ 关键: 基类 MethodInfo 调用虚方法在派生实例上可能不生效 (热更/覆写) →
//    一律用 object_get_class 拿运行时类再查方法, 命中覆写版。
static void *vmi(void *obj, const char *name, int argc) {
    if (!obj || !I.object_get_class || !I.class_get_method_from_name) return NULL;
    Il2CppClass *rc = (Il2CppClass *)I.object_get_class(obj);
    if (!rc) return NULL;
    void *m = I.class_get_method_from_name(rc, name, argc);
    if (m) return m;
    // 沿父链回溯 (最多 8 层)
    Il2CppClass *c = rc;
    for (int i = 0; i < 8 && c; i++) {
        c = I.class_get_parent ? (Il2CppClass *)I.class_get_parent(c) : NULL;
        if (!c) break;
        m = I.class_get_method_from_name(c, name, argc);
        if (m) return m;
    }
    return NULL;
}

static void *vcall(void *obj, const char *name, int argc, void **args) {
    void *m = vmi(obj, name, argc);
    if (!m) return NULL;
    return ic_call(m, obj, args);
}

static BOOL vis_obj(void *obj, const char *name, int argc, void **args) {
    void *m = vmi(obj, name, argc);
    if (!m) return NO;
    Il2CppObject *r = ic_call(m, obj, args);
    if (!r) return NO;
    return *(uint8_t *)((uint8_t *)r + 0x10) ? YES : NO;
}

static int64_t vig_i64(void *obj, const char *name, int argc, void **args) {
    void *m = vmi(obj, name, argc);
    if (!m) return 0;
    Il2CppObject *r = ic_call(m, obj, args);
    return r ? *(int64_t *)((uint8_t *)r + 0x10) : 0;
}

static int32_t vig_i32(void *obj, const char *name, int argc, void **args) {
    void *m = vmi(obj, name, argc);
    if (!m) return 0;
    Il2CppObject *r = ic_call(m, obj, args);
    return r ? *(int32_t *)((uint8_t *)r + 0x10) : 0;
}

// 判断对象是否为某类实例
static BOOL is_inst_of(void *obj, Il2CppClass *k) {
    if (!obj || !k || !I.object_get_class || !I.class_is_assignable_from) return NO;
    Il2CppClass *rc = (Il2CppClass *)I.object_get_class(obj);
    return rc ? (I.class_is_assignable_from(k, rc) ? YES : NO) : NO;
}

// ───────────────────── 世界实例获取 (多路兜底) ─────────────────────
// ① BattleGame.get_World()               (static, 最稳)
// ② UnityEngine.Object.FindObjectOfType(BattleGame) → get_World()  (MonoBehaviour 场景实例)
// ③ WorldBattle.CurLogicWorld 静态字段存在性探测 (间接确认世界已创建)
// (g_worldCache 已在 part3 声明)
static void *m_UO_FindObjectOfType = NULL;   // UnityEngine.Object.FindObjectOfType(Type)
static Il2CppClass *k_UObject = NULL;

static void resolve_world_gate(void) {
    if (m_UO_FindObjectOfType) return;
    Il2CppImage im = ic_find_image("UnityEngine.CoreModule.dll");
    if (!im) im = ic_find_image("UnityEngine.dll");
    if (!im) return;
    k_UObject = I.class_from_name(im, "UnityEngine", "Object");
    if (!k_UObject) return;
    // FindObjectOfType 有多个重载 (Type) / (Type,bool) / 泛型; 取 1 参版
    m_UO_FindObjectOfType = I.class_get_method_from_name(k_UObject, "FindObjectOfType", 1);
    L("world: UnityEngine.Object=%p FindObjectOfType(1)=%p", k_UObject, m_UO_FindObjectOfType);
}

static void *get_world(void) {
    if (!g_parsed) return NULL;
    // ① 静态属性 BattleGame.get_World()
    if (m_BG_getWorld) {
        void *w = ic_call(m_BG_getWorld, NULL, NULL);
        if (w) { g_worldCache = w; return w; }
    }
    // ② FindObjectOfType(BattleGame).get_World()
    if (!m_UO_FindObjectOfType) resolve_world_gate();
    if (m_UO_FindObjectOfType && k_BattleGame && p_class_get_type && p_type_get_object) {
        void *typeObj = ic_type_of(k_BattleGame);
        if (typeObj) {
            void *args[1] = { typeObj };
            Il2CppObject *bg = ic_call(m_UO_FindObjectOfType, NULL, args);
            if (bg) {
                void *w = vcall(bg, "get_World", 0, NULL);
                if (!w && I.class_get_method_from_name) {
                    void *m = I.class_get_method_from_name(k_BattleGame, "get_World", 0);
                    if (m) w = ic_call(m, bg, NULL);
                }
                if (w) { g_worldCache = w; 
                    static int l1 = 0; if (++l1 <= 2) L("world: 走 FindObjectOfType 取得 %p", w);
                    return w;
                }
            }
        }
    }
    return g_worldCache;
}

static void *get_logic_world(void *world) {
    if (!world) return NULL;
    // ① 实例方法 get_LogicWorld()
    void *blw = vcall(world, "get_LogicWorld", 0, NULL);
    if (blw) return blw;
    // ② 静态字段 CurLogicWorld (offset 命中时)
    if (off_CurLogicWorld > 0) {
        void *p = *(void **)((uint8_t *)world + off_CurLogicWorld);
        if (p) return p;
    }
    return NULL;
}

static void *get_ctx(void) {
    void *world = get_world();
    if (!world) return NULL;
    void *blw = get_logic_world(world);
    if (!blw) return NULL;
    if (off_BLW_worldCtx > 0) {
        void *ctx = *(void **)((uint8_t *)blw + off_BLW_worldCtx);
        if (ctx) return ctx;
    }
    return NULL;
}

static void *ctx_entity(void *ctx)     { return (ctx && m_Ctx_getEntity)     ? ic_call(m_Ctx_getEntity, ctx, NULL)     : NULL; }
static void *ctx_battlemgr(void *ctx)  { return (ctx && m_Ctx_getBattleMgr)  ? ic_call(m_Ctx_getBattleMgr, ctx, NULL)  : NULL; }
static void *ctx_battledata(void *ctx) { return (ctx && m_Ctx_getBattleData) ? ic_call(m_Ctx_getBattleData, ctx, NULL) : NULL; }

// GameManager 实例: HotFix.Singleton`1<GameManager>.get_Instance (static)
static void *g_gmCache = NULL;
static void *get_gamemanager(void) {
    if (g_gmCache) return g_gmCache;
    if (!k_GameMgr) return NULL;
    // Singleton`1 泛型实例类的静态 get_Instance; 具体实例类名可能是 GameManager 自身
    void *mi = I.class_get_method_from_name(k_GameMgr, "get_Instance", 0);
    if (!mi && I.class_get_fields) {
        // GameManager 若有静态字段 (Singleton.m_t) 也可直接读
    }
    if (mi) {
        Il2CppObject *o = ic_call(mi, NULL, NULL);
        if (o) { g_gmCache = o; L("GameManager.Instance = %p", o); return o; }
    }
    static int l = 0; if (++l <= 2) L("GameManager.get_Instance 未命中 (mi=%p)", mi);
    return NULL;
}

static BOOL battle_alive(void) {
    void *world = get_world();
    if (!world) return NO;
    if (!get_logic_world(world)) return NO;
    if (!get_ctx()) return NO;
    return YES;
}

// ───────────────────── 通用 MethodInfo 热替换 (零 __TEXT patch) ─────────────────────
// 原理: il2cpp MethodInfo 里的 methodPointer 是【数据段函数指针】, 改写它
//       不影响代码段、无需 mprotect 代码页、无 icache 风险。
//       HybridCLR 解释器执行 call 时会读取该指针 → 替换对热更方法同样生效。
// ⚠️ 不采用 inline hook: arm64 序言含 ADRP/ADD 等 PC 相对指令, 覆写极易踩雷。
//
// MethodInfo 布局 (il2cpp v31, arm64) 实测探测:
//   +0x00 methodPointer (指向 __TEXT)
//   +0x10 name (const char*)
// 探测法: 用 method_get_name() 的返回值做【指针相等】比较定位 name 字段,
//         同时找第一个落在 __TEXT 的指针作为 methodPointer。

typedef struct {
    uintptr_t  *slot;        // methodPointer 所在地址
    uintptr_t   orig;        // 原函数指针
    void       *mi;
    const char *name;
    int         hits;
} dk_hook_rec_t;

static dk_hook_rec_t g_hooks[8];
static int g_hookN = 0;

// 安全读指针指向的字符串是否等于 want (用 SIGSEGV 守卫保护)
static int ptr_eq_cstr(uintptr_t v, const char *want) {
    if (!v || !want || v < 0x1000) return 0;
    int ok = 0;
    if (DK_GUARD_BEGIN() == 0) {
        const char *s = (const char *)v;
        ok = (s == want) ? 1 : 0;                 // 指针相等
        if (!ok) ok = (strcmp(s, want) == 0) ? 2 : 0;  // 内容相等
    }
    DK_GUARD_END();
    return ok;
}

static void *dk_hook_method(void *mi, void *replacement, const char *tag);

// 找 methodPointer 槽位; 返回槽地址
static uintptr_t *find_methodptr_slot(void *mi, const char *tag) {
    if (!mi) return NULL;
    const char *want = (I.method_get_name) ? I.method_get_name(mi) : NULL;
    uint8_t *p = (uint8_t *)mi;
    int nameOff = -1, ptrOff = -1;
    int g = DK_GUARD_BEGIN();
    if (g == 0) {
        for (int off = 0; off <= 96; off += 8) {
            uintptr_t v = *(uintptr_t *)(p + off);
            if (!v) continue;
            if (nameOff < 0 && want && ptr_eq_cstr(v, want)) { nameOff = off; continue; }
            if (ptrOff < 0 && dk_ptr_executable(v)) ptrOff = off;
        }
    }
    DK_GUARD_END();
    if (ptrOff < 0) {
        L("hook[%s]: methodPointer 未定位 (nameOff=%d want=%s)", tag, nameOff, want ? want : "?");
        return NULL;
    }
    if (nameOff < 0 && want) {
        // name 字段未能用指针比较命中 → 布局异常, 仍尝试 (打印告警)
        L("hook[%s]: ⚠️ name 字段未命中, methodPointer@%d (方法名=%s 不可信)", tag, ptrOff, want);
    }
    L("hook[%s]: name@%d methodPointer@%d (name=%s)", tag, nameOff, ptrOff, want ? want : "?");
    return (uintptr_t *)(p + ptrOff);
}

static void *dk_hook_method(void *mi, void *replacement, const char *tag) {
    if (!mi || !replacement || g_hookN >= 8) return NULL;
    uintptr_t *slot = find_methodptr_slot(mi, tag);
    if (!slot) return NULL;
    // 确保页可写 (MethodInfo 通常在 il2cpp metadata/GC 区, 多数已可写)
    vm_prot_t cur = 0, max = 0;
    vm_address_t pg = (vm_address_t)((uintptr_t)slot & ~(uintptr_t)(vm_page_size - 1));
    vm_size_t sz = vm_page_size;
    if (vm_region_64(mach_task_self(), &pg, &sz, &max, NULL, NULL, NULL, NULL) == KERN_SUCCESS) {
        if (!(max & VM_PROT_WRITE)) {
            kern_return_t kr = vm_protect(mach_task_self(), pg, sz, FALSE, max | VM_PROT_WRITE);
            if (kr != KERN_SUCCESS) L("hook[%s]: vm_protect 失败 (kr=%d)", tag, kr);
        }
    }
    g_hooks[g_hookN].slot = slot;
    g_hooks[g_hookN].orig = *slot;
    g_hooks[g_hookN].mi   = mi;
    g_hooks[g_hookN].name = tag;
    g_hooks[g_hookN].hits = 0;
    *slot = (uintptr_t)replacement;
    L("hook[%s]: 安装成功 %p → %p (slot=%p)", tag, (void *)g_hooks[g_hookN].orig, replacement, slot);
    g_hookN++;
    return slot;
}

static void dk_unhook_all(void) {
    for (int i = 0; i < g_hookN; i++) {
        if (g_hooks[i].slot) *g_hooks[i].slot = g_hooks[i].orig;
    }
    if (g_hookN) L("hook: 全部 %d 个已还原", g_hookN);
    g_hookN = 0;
}

// ───────────────────── ⑤ 免广告实现 ─────────────────────
// 主方案: 替换 ADModuleMgr.CheckAndPlayVideo(callback, source)
//         → 跳过视频, 直接调用传入的 callback(发奖委托)
// 辅方案: 替换 GorillaAd.Runtime.LocalRewardedVideoAd.Show() → 触发 OnRewarded/OnClosed
// 兜底:   若 CheckAndPlayVideo 无参数回调, 读实例字段 _onClose 委托并 Invoke
static uintptr_t *g_adSlot = NULL;

// 判定对象是否为委托 (C# Delegate): 类名含 Action/Func/Callback/<> 或继承 MulticastDelegate
static int looks_like_delegate(void *obj) {
    if (!obj || !I.object_get_class || !I.class_get_name) return 0;
    Il2CppClass *k = (Il2CppClass *)I.object_get_class(obj);
    if (!k) return 0;
    const char *nm = I.class_get_name(k);
    if (!nm) return 0;
    if (strstr(nm, "Action") || strstr(nm, "Func") || strstr(nm, "Callback")
        || strstr(nm, "Delegate") || strstr(nm, "<>") || strstr(nm, "Predicate")) return 1;
    // 沿父链检查 MulticastDelegate
    Il2CppClass *c = k;
    for (int i = 0; i < 6 && c; i++) {
        const char *n = I.class_get_name(c);
        if (n && (strstr(n, "MulticastDelegate") || strstr(n, "Delegate"))) return 1;
        c = I.class_get_parent ? (Il2CppClass *)I.class_get_parent(c) : NULL;
    }
    return 0;
}

static int delegate_invoke(void *obj) {
    if (!obj || !I.object_get_class) return 0;
    Il2CppClass *k = (Il2CppClass *)I.object_get_class(obj);
    if (!k) return 0;
    void *mi = I.class_get_method_from_name ? I.class_get_method_from_name(k, "Invoke", 0) : NULL;
    if (!mi) {
        Il2CppClass *c = k;
        for (int i = 0; i < 5 && c && !mi; i++) {
            c = I.class_get_parent ? (Il2CppClass *)I.class_get_parent(c) : NULL;
            if (c) mi = I.class_get_method_from_name(c, "Invoke", 0);
        }
    }
    if (!mi) return 0;
    ic_call(mi, obj, NULL);
    return 1;
}

// 替换实现: 参数扫描 → 找 delegate 参数 → 立即 Invoke (模拟"广告已看完")
// ⚠️ 只能 hook 签名已知的方法; 参数个数不足时安全跳过。
static int  g_adHooked = 0;
static void *ad_hook_self = NULL;   // 记录最近一次实例 (供 _onClose 兜底)

static void ad_replacement_2(void *self, void *a1, void *a2) {
    g_hooks[0].hits++;
    ad_hook_self = self;
    static int l = 0;
    if (l++ < 6) L("⑤ noAd: 拦截 CheckAndPlayVideo(self=%p a1=%p a2=%p)", self, a1, a2);
    int fired = 0;
    if (a1 && looks_like_delegate(a1)) fired += delegate_invoke(a1);
    if (a2 && looks_like_delegate(a2)) fired += delegate_invoke(a2);
    if (!fired && self && off_AD_onClose > 0) {
        void *d = *(void **)((uint8_t *)self + off_AD_onClose);
        if (d) fired += delegate_invoke(d);
    }
    if (l <= 6) L("⑤ noAd: 发奖回调触发 %d 次", fired);
}

// LocalRewardedVideoAd.Show() (无参) → 直接触发 OnRewarded/OnClosed
static void ad_replacement_show0(void *self) {
    if (g_hookN > 1) g_hooks[1].hits++;
    ad_hook_self = self;
    static int l = 0;
    if (l++ < 6) L("⑤ noAd: 拦截 LocalRewardedVideoAd.Show(self=%p)", self);
    // 委托字段名: OnRewarded / OnClosed / OnShowSuccess
    const char *fns[] = { "OnRewarded", "OnClosed", "OnShowSuccess" };
    int fired = 0;
    for (int i = 0; i < 3; i++) {
        int32_t off = foff((Il2CppClass *)I.object_get_class(self), fns[i]);
        if (off > 0) {
            void *d = *(void **)((uint8_t *)self + off);
            if (d && looks_like_delegate(d)) fired += delegate_invoke(d);
        }
    }
    if (l <= 6) L("⑤ noAd: LocalShow 发奖 %d 次", fired);
}

static void ad_hook_install(void) {
    if (g_adHooked) return;
    if (!g_parsed) return;
    if (m_AD_CheckAndPlayVideo) {
        if (dk_hook_method(m_AD_CheckAndPlayVideo, (void *)ad_replacement_2, "ADMgr.CheckAndPlayVideo"))
            g_adHooked++;
    }
    if (m_Ad_Show0) {
        if (dk_hook_method(m_Ad_Show0, (void *)ad_replacement_show0, "LocalRewardedVideoAd.Show"))
            g_adHooked++;
    }
    L("⑤ noAd: hook 安装结果 hooked=%d (CheckAndPlayVideo=%p LocalShow=%p)",
      g_adHooked, m_AD_CheckAndPlayVideo, m_Ad_Show0);
}

static void ad_hook_remove(void) {
    dk_unhook_all();
    g_adHooked = 0;
    L("⑤ noAd: hook 已移除");
}

// ───────────────────── 功能 ① 怪物自杀 / 秒杀 ─────────────────────
// 路线1 (首选): EntityManager.EnemyCommitSuicide(entity, reason) — 引擎自带自杀入口
// 路线2 (兜底): EntityCharacter.SetHp(0) → 覆写 setter 使 IsDead 成立 → OnDeath(tdd) 驱动表现/掉落
static int   g_killScanned = 0, g_killDone = 0, g_killSkip = 0;

static void do_kill(void) {
    void *ctx = get_ctx();
    if (!ctx) return;
    void *em = ctx_entity(ctx);
    if (!em || !m_EM_GetEntityValues) return;
    void *list = ic_call(m_EM_GetEntityValues, em, NULL);
    if (!list) return;
    int32_t size = list_size(list);
    if (size <= 0) return;
    if (size > 800) size = 800;

    // 玩家指针集合 (GetAllPlayer → EntityHero[])
    void *players[8] = {0};
    int pc = 0;
    if (m_EM_GetAllPlayer) {
        void *parr = ic_call(m_EM_GetAllPlayer, em, NULL);
        if (parr) {
            int32_t pn = arr_len(parr);
            if (pn > 8) pn = 8;
            for (int i = 0; i < pn; i++) players[i] = arr_at(parr, i);
            pc = pn;
        }
    }
    int sc = 0, dl = 0, sk = 0;
    for (int i = 0; i < size; i++) {
        void *e = list_at(list, i);
        if (!e) continue;
        // 排除玩家
        int isPlayer = 0;
        for (int p = 0; p < pc; p++) if (e == players[p]) { isPlayer = 1; break; }
        if (isPlayer) { sk++; continue; }
        // 必须是 EntityCharacter (怪物/召唤物都在其下)
        Il2CppClass *cls = I.object_get_class ? (Il2CppClass *)I.object_get_class(e) : NULL;
        if (!cls || !I.class_is_assignable_from) continue;
        if (!I.class_is_assignable_from(k_Char, cls)) continue;
        if (k_Hero && I.class_is_assignable_from(k_Hero, cls)) { sk++; continue; }   // 英雄侧跳过
        // 已死跳过
        if (m_Char_getIsDead) {
            Il2CppObject *dead = ic_call(m_Char_getIsDead, e, NULL);
            if (dead && *(uint8_t *)((uint8_t *)dead + 0x10)) continue;
        }
        sc++;
        // 路线1: EnemyCommitSuicide
        BOOL ok = NO;
        if (m_EM_GetEntityValues && k_EM) {
            static void *m_commit = NULL;
            if (!m_commit) m_commit = I.class_get_method_from_name(k_EM, "EnemyCommitSuicide", 2);
            if (m_commit) {
                // (EntityCharacter entity, int reason) — reason 用 0
                void *args[2] = { e, NULL };
                int32_t reason = 0;
                args[1] = &reason;
                ic_call(m_commit, em, args);
                ok = YES;
            }
        }
        // 路线2: SetHp(0) + OnDeath
        if (!ok) {
            if (m_Char_SetHp) {
                int64_t zero = 0;
                void *args[1] = { &zero };
                ic_call(m_Char_SetHp, e, args);
            }
            if (m_Char_OnDeath && k_TDD && I.object_new) {
                Il2CppObject *tdd = I.object_new(k_TDD);
                if (tdd) {
                    uint8_t *t = (uint8_t *)tdd;
                    *(uint8_t  *)(t + 0x18) = 1;            // UseDeathVibration
                    *(int32_t  *)(t + 0x1C) = 6;            // AttackerType.GM
                    *(uint64_t *)(t + 0x28) = 999999999ULL; // HurtValue
                    void *args[1] = { tdd };
                    ic_call(m_Char_OnDeath, e, args);
                }
            }
        }
        dl++;
    }
    g_killScanned = sc; g_killDone = dl; g_killSkip = sk;
    static int kl = 0;
    if (++kl <= 3 || kl % 40 == 0) L("① kill: 扫描%d 清%d 跳%d (玩家%d)", sc, dl, sk, pc);
}

// ───────────────────── 功能 ② 无敌 ─────────────────────
// AddAbsoluteInvincibility() (首选, 无参) + set_CurrentHp(999999999) + AddCharacterStatus(ImmuneDamage=2)
static void do_invincible(void) {
    void *ctx = get_ctx();
    if (!ctx) return;
    void *em = ctx_entity(ctx);
    if (!em) return;
    // 玩家英雄: GetAllPlayer → 逐个
    void *heroes[4] = {0};
    int hn = 0;
    if (m_EM_GetAllPlayer) {
        void *parr = ic_call(m_EM_GetAllPlayer, em, NULL);
        if (parr) {
            int32_t pn = arr_len(parr); if (pn > 4) pn = 4;
            for (int i = 0; i < pn; i++) heroes[i] = arr_at(parr, i);
            hn = pn;
        }
    }
    // 兜底: GetEntityValues 里筛 EntityHero
    if (hn == 0 && m_EM_GetEntityValues && I.class_is_assignable_from) {
        void *list = ic_call(m_EM_GetEntityValues, em, NULL);
        if (list) {
            int32_t n = list_size(list); if (n > 800) n = 800;
            for (int i = 0; i < n && hn < 4; i++) {
                void *e = list_at(list, i);
                if (!e) continue;
                Il2CppClass *cls = I.object_get_class ? (Il2CppClass *)I.object_get_class(e) : NULL;
                if (cls && k_Hero && I.class_is_assignable_from(k_Hero, cls)) heroes[hn++] = e;
            }
        }
    }
    for (int i = 0; i < hn; i++) {
        void *h = heroes[i];
        if (!h) continue;
        // ① 绝对无敌
        if (m_Char_AddAbsInv) ic_call(m_Char_AddAbsInv, h, NULL);
        // ② 血量拉满 (覆写 setter)
        void *setHp = m_Char_setCurrentHp;
        if (!setHp && I.object_get_class) {
            Il2CppClass *rc = (Il2CppClass *)I.object_get_class(h);
            if (rc) setHp = I.class_get_method_from_name(rc, "set_CurrentHp", 1);
        }
        if (setHp) {
            int64_t big = 999999999LL;
            void *args[1] = { &big };
            ic_call(setHp, h, args);
        }
        // ③ 免疫伤害状态
        if (m_Char_AddStatus) {
            int32_t st = 2;   // CharacterStatusType.ImmuneDamage (枚举序 None=0,ImmuneSelect=1,ImmuneDamage=2)
            void *args[1] = { &st };
            ic_call(m_Char_AddStatus, h, args);
        }
    }
    static int il = 0;
    if (++il <= 3 || il % 60 == 0) L("② inv: 英雄%d abs=%p setHp=%p status=%p", hn, m_Char_AddAbsInv, m_Char_setCurrentHp, m_Char_AddStatus);
}

// ───────────────────── 功能 ③ 一键通关 ─────────────────────
// 路线1: BattleManager.OnMissionClear() → 本关通过判定
// 路线2: 先清场 (do_kill) 再 OnMissionClear / OnChapterEnd
static void do_pass_chapter(void) {
    void *ctx = get_ctx();
    if (!ctx) { if (g_statusSub) g_statusSub.text = @"未在战斗中"; return; }
    // 先清场 (最后一波怪物必须死光才会触发通关判定)
    do_kill();
    void *bm = ctx_battlemgr(ctx);
    if (!bm) { if (g_statusSub) g_statusSub.text = @"BattleManager 未就绪"; return; }
    if (m_BM_OnMissionClear) ic_call(m_BM_OnMissionClear, bm, NULL);
    if (m_BM_OnChapterEnd)   ic_call(m_BM_OnChapterEnd, bm, NULL);
    L("③ pass: OnMissionClear=%p OnChapterEnd=%p 已触发", m_BM_OnMissionClear, m_BM_OnChapterEnd);
    if (g_statusSub) g_statusSub.text = @"一键通关已触发 (清场+过关判定)";
}

// ───────────────────── 功能 ④ 游戏加速 ─────────────────────
// 路线1 (最稳): HotFix.GameManager.SetTimeScale(float)  — 游戏官方加速入口
// 路线2        HotFix.Game.SetTimeScale(float)          — 静态门面
// 路线3        WorldContext.gameSpeed 直写 (Q16.16 定点, 帧同步确定性时基)
static void do_speed(void) {
    float f = g_speedMult;
    int done = 0;
    // 路线1: GameManager 实例
    if (m_GM_SetTimeScale) {
        void *gm = get_gamemanager();
        if (gm) {
            void *args[1] = { &f };
            ic_call(m_GM_SetTimeScale, gm, args);
            done++;
        }
    }
    // 路线2: Game.SetTimeScale (static)
    if (m_Game_SetTimeScale) {
        void *args[1] = { &f };
        ic_call(m_Game_SetTimeScale, NULL, args);
        done++;
    }
    // 路线3: 直写 gameSpeed
    void *ctx = get_ctx();
    if (ctx && off_Ctx_gameSpeed > 0) {
        *(uint64_t *)((uint8_t *)ctx + off_Ctx_gameSpeed) = (uint64_t)(f * 65536.0f);
        done++;
    }
    void *world = get_world();
    if (world && off_World_timeScale > 0) *(float *)((uint8_t *)world + off_World_timeScale) = f;
    static int sl = 0;
    if (++sl <= 4 || sl % 60 == 0) {
        uint64_t rb = (ctx && off_Ctx_gameSpeed > 0) ? *(uint64_t *)((uint8_t *)ctx + off_Ctx_gameSpeed) : 0;
        L("④ speed: %.2fx done=%d (GM=%p Game=%p) gameSpeed回读=%.2f",
          f, done, m_GM_SetTimeScale, m_Game_SetTimeScale, (double)rb / 65536.0);
    }
}

static void restore_speed(void) {
    float f = 1.0f;
    if (m_GM_SetTimeScale) { void *gm = get_gamemanager(); if (gm) { void *a[1] = { &f }; ic_call(m_GM_SetTimeScale, gm, a); } }
    if (m_Game_SetTimeScale) { void *a[1] = { &f }; ic_call(m_Game_SetTimeScale, NULL, a); }
    void *ctx = get_ctx();
    if (ctx && off_Ctx_gameSpeed > 0) *(uint64_t *)((uint8_t *)ctx + off_Ctx_gameSpeed) = 65536ULL;
    void *world = get_world();
    if (world && off_World_timeScale > 0) *(float *)((uint8_t *)world + off_World_timeScale) = 1.0f;
    L("④ speed: 恢复 1.0x");
}

// ───────────────────── 功能 ⑤ 免广告 ─────────────────────
// 原理: 广告播放入口 ADModuleMgr.CheckAndPlayVideo(callback, source) 内部调原生 SDK 播视频,
//       播完回调 _onClose 发奖。免广告 = 跳过播放直接调回调发奖。
// 实现: MethodInfo->methodPointer 热替换 (数据段函数指针, 零 __TEXT patch, 零 icache 风险)
//       实现在 part5 (ad_hook) — 此处仅提供开关入口与状态。
static void do_no_ad(void) {
    if (g_noAdOn) ad_hook_install(); else ad_hook_remove();
    static int nl = 0;
    if (++nl <= 3) L("⑤ noAd: 开关=%d CheckAndPlayVideo=%p hookSlot=%p",
                     g_noAdOn, m_AD_CheckAndPlayVideo, g_ad_mp_slot);
}

// ───────────────────── 功能 ⑥ 局内经验 ─────────────────────
static void do_add_exp(void) {
    void *ctx = get_ctx();
    if (!ctx) { if (g_statusSub) g_statusSub.text = @"未在战斗中"; return; }
    void *bd = ctx_battledata(ctx);
    int done = 0;
    if (bd && m_BD_AddUserExp) {
        int32_t v = g_expValue;
        void *args[1] = { &v };
        ic_call(m_BD_AddUserExp, bd, args);
        done++;
    }
    // 同时触发结算型经验 (BattleManager.AddExpAndGold)
    void *bm = ctx_battlemgr(ctx);
    if (bm && m_BM_AddExpAndGold) { ic_call(m_BM_AddExpAndGold, bm, NULL); done++; }
    L("⑥ exp: BattleData.AddUserExp(%d)=%d BM.AddExpAndGold=%d done=%d", g_expValue,
      m_BD_AddUserExp ? 1 : 0, m_BM_AddExpAndGold ? 1 : 0, done);
    if (g_statusSub) g_statusSub.text = [NSString stringWithFormat:@"已加经验 +%d", g_expValue];
}

// ───────────────────── 功能 ⑦ 局内金币 ─────────────────────
static void do_add_gold(void) {
    void *ctx = get_ctx();
    if (!ctx) { if (g_statusSub) g_statusSub.text = @"未在战斗中"; return; }
    void *bd = ctx_battledata(ctx);
    if (!bd) { if (g_statusSub) g_statusSub.text = @"BattleData 未就绪"; return; }
    int32_t v = g_goldValue;
    void *args[1] = { &v };
    if (m_BD_AddDropGold) ic_call(m_BD_AddDropGold, bd, args);   // 掉落金币
    if (m_BD_AddWaveGold) ic_call(m_BD_AddWaveGold, bd, args);   // 波次金币
    L("⑦ gold: AddDropGold(%d)=%p AddWaveGold=%p", g_goldValue, m_BD_AddDropGold, m_BD_AddWaveGold);
    if (g_statusSub) g_statusSub.text = [NSString stringWithFormat:@"已加金币 +%d", g_goldValue];
}
// ───────────────────── 主循环 tick ─────────────────────
static void combat_tick(void) {
    if (!ic_ready) return;
    if (!g_parsed) return;
    int g = DK_GUARD_BEGIN();
    if (g == 0) {
        BOOL alive = battle_alive();
        static BOOL wasIn = NO;
        if (alive != wasIn) {
            wasIn = alive; g_inBattle = alive;
            L(">> %s战斗 (world=%p ctx=%p)", alive ? "进入" : "离开", get_world(), get_ctx());
            dispatch_async(dispatch_get_main_queue(), ^{
                if (g_statusSub) g_statusSub.text = alive ? @"战斗中 ✓ 功能即时生效" : @"已就绪，进入关卡后生效";
            });
        }
        if (g_noAdOn) ad_hook_install(); else ad_hook_remove();
        if (alive) {
            if (g_killOn)  do_kill();
            if (g_invOn)   do_invincible();
            if (g_speedOn) do_speed();
            else if (g_speedWasOn) { restore_speed(); }
        }
        g_speedWasOn = g_speedOn;
        DK_GUARD_END();
        return;
    }
    // SIGSEGV 兜底恢复
    L("⚠️ tick 捕获异常 (SIGSEGV 守卫生效) — 本次跳过");
    DK_GUARD_END();
}

// ───────────────────── UI: 卡片面板 ─────────────────────
#define DK_TEAL   [UIColor colorWithRed:0.243 green:0.714 blue:0.761 alpha:1]
#define DK_TEALBG [UIColor colorWithRed:0.874 green:0.953 blue:0.961 alpha:1]
#define DK_RED    [UIColor colorWithRed:0.992 green:0.906 blue:0.906 alpha:1]
#define DK_BLUE   [UIColor colorWithRed:0.910 green:0.941 blue:1.0 alpha:1]
#define DK_GREEN  [UIColor colorWithRed:0.910 green:0.973 blue:0.933 alpha:1]
#define DK_GOLD   [UIColor colorWithRed:1.0 green:0.949 blue:0.855 alpha:1]
#define DK_TEXT   [UIColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:1]
#define DK_SUB    [UIColor colorWithRed:0.55 green:0.55 blue:0.60 alpha:1]

@interface DK3Helper : NSObject <UIGestureRecognizerDelegate>
- (void)ballTapped;
- (void)ballPan:(UIPanGestureRecognizer *)gr;
- (void)panelPan:(UIPanGestureRecognizer *)gr;
- (void)closeTapped;
- (void)killSw:(UISwitch *)sw;
- (void)invSw:(UISwitch *)sw;
- (void)speedSw:(UISwitch *)sw;
- (void)noAdSw:(UISwitch *)sw;
- (void)passTap;
- (void)expGo;
- (void)goldGo;
- (void)expDec; - (void)expInc;
- (void)goldDec; - (void)goldInc;
- (void)spdDec; - (void)spdInc;
@end

static CGPoint dk_clamp(CGPoint c, CGSize sz, CGRect bounds) {
    CGFloat hw = sz.width / 2, hh = sz.height / 2;
    c.x = MAX(hw + 4, MIN(bounds.size.width - hw - 4, c.x));
    c.y = MAX(hh + 30, MIN(bounds.size.height - hh - 20, c.y));
    return c;
}

@implementation DK3Helper
- (void)ballTapped { g_panel.hidden = !g_panel.hidden; }
- (void)ballPan:(UIPanGestureRecognizer *)gr {
    CGPoint t = [gr translationInView:gr.view.superview];
    if (gr.state == UIGestureRecognizerStateBegan || gr.state == UIGestureRecognizerStateChanged) {
        CGPoint c = gr.view.center;
        c.x += t.x; c.y += t.y;
        gr.view.center = dk_clamp(c, gr.view.bounds.size, gr.view.superview.bounds);
        [gr setTranslation:CGPointZero inView:gr.view.superview];
    }
}
- (void)panelPan:(UIPanGestureRecognizer *)gr {
    CGPoint t = [gr translationInView:g_panel.superview];
    if (gr.state == UIGestureRecognizerStateBegan || gr.state == UIGestureRecognizerStateChanged) {
        CGPoint c = g_panel.center;
        c.x += t.x; c.y += t.y;
        g_panel.center = dk_clamp(c, g_panel.bounds.size, g_panel.superview.bounds);
        [gr setTranslation:CGPointZero inView:g_panel.superview];
    }
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    if (gr == g_panelPan && g_panel) {
        CGPoint p = [gr locationInView:g_panel];
        for (UIView *v in g_panel.subviews)
            if ([v isKindOfClass:[UIControl class]] && CGRectContainsPoint(v.frame, p)) return NO;
    }
    return YES;
}
- (void)closeTapped { g_panel.hidden = YES; }
- (void)killSw:(UISwitch *)sw  { g_killOn  = sw.on; [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:@"dk3_kill"]; L("①秒杀→%d", sw.on); }
- (void)invSw:(UISwitch *)sw   { g_invOn   = sw.on; [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:@"dk3_inv"];  L("②无敌→%d", sw.on); }
- (void)speedSw:(UISwitch *)sw { g_speedOn = sw.on; [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:@"dk3_spd"];
                                 if (!sw.on) restore_speed(); L("④加速→%d (%.1fx)", sw.on, g_speedMult); }
- (void)noAdSw:(UISwitch *)sw  { g_noAdOn  = sw.on; [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:@"dk3_noad"];
                                 if (sw.on) ad_hook_install(); else ad_hook_remove(); L("⑤免广告→%d", sw.on); }
- (void)passTap { do_pass_chapter(); }
- (void)expGo   { do_add_exp(); }
- (void)goldGo  { do_add_gold(); }
- (void)expDec  { if (g_expValue > 100) g_expValue -= 100;  g_expVal.text  = [NSString stringWithFormat:@"%d", g_expValue]; }
- (void)expInc  { if (g_expValue < 100000) g_expValue += 100; g_expVal.text = [NSString stringWithFormat:@"%d", g_expValue]; }
- (void)goldDec { if (g_goldValue > 100) g_goldValue -= 100; g_goldVal.text = [NSString stringWithFormat:@"%d", g_goldValue]; }
- (void)goldInc { if (g_goldValue < 100000) g_goldValue += 100; g_goldVal.text = [NSString stringWithFormat:@"%d", g_goldValue]; }
- (void)spdDec  { if (g_speedMult > 0.5f) g_speedMult -= 0.5f; g_spdVal.text = [NSString stringWithFormat:@"%.1fx", g_speedMult]; }
- (void)spdInc  { if (g_speedMult < 8.0f) g_speedMult += 0.5f; g_spdVal.text = [NSString stringWithFormat:@"%.1fx", g_speedMult]; }
@end
static DK3Helper *g_helper = nil;

static UILabel *mkLabel(NSString *t, CGFloat sz, CGFloat w, UIColor *c, CGRect f, UIView *p) {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.text = t; l.font = [UIFont systemFontOfSize:sz weight:w];
    l.textColor = c; [p addSubview:l]; return l;
}
static UIView *mkCard(CGRect f, UIView *p) {
    UIView *c = [[UIView alloc] initWithFrame:f];
    c.backgroundColor = UIColor.whiteColor;
    c.layer.cornerRadius = 14;
    c.layer.shadowColor = UIColor.blackColor.CGColor;
    c.layer.shadowOpacity = 0.06; c.layer.shadowOffset = CGSizeMake(0, 2); c.layer.shadowRadius = 4;
    [p addSubview:c]; return c;
}
static UIView *mkIcon(NSString *e, UIColor *bg, CGRect f, UIView *p) {
    UIView *v = [[UIView alloc] initWithFrame:f];
    v.backgroundColor = bg; v.layer.cornerRadius = f.size.width * 0.28;
    [p addSubview:v];
    UILabel *l = [[UILabel alloc] initWithFrame:v.bounds];
    l.text = e; l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:f.size.width * 0.5];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [v addSubview:l]; return v;
}
static UISwitch *mkSw(CGRect f, BOOL on, id tgt, SEL sel, UIView *p) {
    UISwitch *s = [[UISwitch alloc] initWithFrame:f];
    s.on = on; s.onTintColor = DK_TEAL;
    s.transform = CGAffineTransformMakeScale(0.78, 0.78);
    [s addTarget:tgt action:sel forControlEvents:UIControlEventValueChanged];
    [p addSubview:s]; return s;
}
static UIView *mkToggleCard(CGRect f, NSString *emoji, UIColor *bg, NSString *title, NSString *sub,
                            BOOL on, id tgt, SEL sel, UIView *p) {
    UIView *c = mkCard(f, p);
    mkIcon(emoji, bg, CGRectMake(8, (f.size.height - 28) / 2, 28, 28), c);
    mkLabel(title, 13, UIFontWeightSemibold, DK_TEXT, CGRectMake(42, 4, f.size.width - 96, 16), c);
    UILabel *s = mkLabel(sub, 9, UIFontWeightRegular, DK_SUB, CGRectMake(42, 20, f.size.width - 96, 26), c);
    s.numberOfLines = 2;
    mkSw(CGRectMake(f.size.width - 50, (f.size.height - 31) / 2, 51, 31), on, tgt, sel, c);
    return c;
}
// 步进卡: − 值 ＋
static UIView *mkStepCard(CGRect f, NSString *emoji, UIColor *bg, NSString *title, NSString *sub,
                          UILabel **outVal, id tgt, SEL dec, SEL inc, UIView *p) {
    UIView *c = mkCard(f, p);
    mkIcon(emoji, bg, CGRectMake(8, (f.size.height - 28) / 2, 28, 28), c);
    mkLabel(title, 13, UIFontWeightSemibold, DK_TEXT, CGRectMake(42, 4, f.size.width - 150, 16), c);
    UILabel *s = mkLabel(sub, 9, UIFontWeightRegular, DK_SUB, CGRectMake(42, 20, f.size.width - 150, 26), c);
    s.numberOfLines = 2;
    CGFloat bx = f.size.width - 92;
    UIButton *d = [UIButton buttonWithType:UIButtonTypeCustom];
    d.frame = CGRectMake(bx, (f.size.height - 26) / 2, 26, 26);
    d.backgroundColor = DK_TEALBG; d.layer.cornerRadius = 13;
    [d setTitle:@"−" forState:UIControlStateNormal];
    [d setTitleColor:DK_TEAL forState:UIControlStateNormal];
    d.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [d addTarget:tgt action:dec forControlEvents:UIControlEventTouchUpInside];
    [c addSubview:d];
    UILabel *v = mkLabel(@"1000", 13, UIFontWeightBold, DK_TEAL, CGRectMake(bx + 28, (f.size.height - 18) / 2, 40, 18), c);
    v.textAlignment = NSTextAlignmentCenter; v.adjustsFontSizeToFitWidth = YES;
    *outVal = v;
    UIButton *u = [UIButton buttonWithType:UIButtonTypeCustom];
    u.frame = CGRectMake(bx + 68, (f.size.height - 26) / 2, 26, 26);
    u.backgroundColor = DK_TEALBG; u.layer.cornerRadius = 13;
    [u setTitle:@"+" forState:UIControlStateNormal];
    [u setTitleColor:DK_TEAL forState:UIControlStateNormal];
    u.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [u addTarget:tgt action:inc forControlEvents:UIControlEventTouchUpInside];
    [c addSubview:u];
    return c;
}
// 大动作按钮卡
static UIView *mkGoCard(CGRect f, NSString *emoji, UIColor *bg, NSString *title, id tgt, SEL sel, UIView *p) {
    UIView *c = mkCard(f, p);
    c.layer.cornerRadius = 18;
    mkIcon(emoji, bg, CGRectMake(8, (f.size.height - 40) / 2, 40, 40), c);
    mkLabel(title, 16, UIFontWeightBold, DK_TEXT, CGRectMake(58, 0, f.size.width - 130, f.size.height), c);
    UIButton *go = [UIButton buttonWithType:UIButtonTypeCustom];
    go.frame = CGRectMake(f.size.width - 56, (f.size.height - 40) / 2, 40, 40);
    go.backgroundColor = DK_TEAL; go.layer.cornerRadius = 20;
    [go setTitle:@"▶" forState:UIControlStateNormal];
    [go setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    go.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [go addTarget:tgt action:sel forControlEvents:UIControlEventTouchUpInside];
    [c addSubview:go];
    return c;
}

static UIWindow *dk_game_window(void) {
    UIWindow *w = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    id<UIApplicationDelegate> dg = UIApplication.sharedApplication.delegate;
    if ([dg respondsToSelector:@selector(window)]) w = [(id)dg window];
#pragma clang diagnostic pop
    if (!w) {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
            if ([sc isKindOfClass:[UIWindowScene class]])
                for (UIWindow *ww in ((UIWindowScene *)sc).windows)
                    if (ww.isKeyWindow) { w = ww; break; }
    }
    if (!w) w = UIApplication.sharedApplication.windows.firstObject;
    return w;
}

static void dk_build_ui(void) {
    UIWindow *win = dk_game_window();
    if (!win) { L("UI: 游戏 window 未就绪"); return; }
    CGFloat W = MIN(300, win.bounds.size.width - 24);
    CGFloat x = (win.bounds.size.width - W) / 2;
    CGFloat y = 74;
    g_panel = [[UIView alloc] initWithFrame:CGRectMake(x, y, W, 470)];
    g_panel.backgroundColor = [UIColor colorWithRed:0.949 green:0.949 blue:0.973 alpha:1];
    g_panel.layer.cornerRadius = 20;
    g_panel.layer.shadowColor = UIColor.blackColor.CGColor;
    g_panel.layer.shadowOpacity = 0.25; g_panel.layer.shadowOffset = CGSizeMake(0, 6); g_panel.layer.shadowRadius = 14;
    g_panel.hidden = YES;
    [win addSubview:g_panel];

    CGFloat pad = 12, cw = (W - pad * 3) / 2, ch = 56;
    // 标题栏
    mkLabel(@"弹壳战机 · 全功能", 15, UIFontWeightBold, DK_TEXT, CGRectMake(pad, 12, W - 80, 20), g_panel);
    g_statusSub = mkLabel(@"初始化中…", 9, UIFontWeightRegular, DK_SUB, CGRectMake(pad, 30, W - 80, 14), g_panel);
    UIButton *x = [UIButton buttonWithType:UIButtonTypeCustom];
    x.frame = CGRectMake(W - 40, 14, 26, 26);
    x.backgroundColor = DK_RED; x.layer.cornerRadius = 13;
    [x setTitle:@"✕" forState:UIControlStateNormal];
    [x setTitleColor:[UIColor colorWithRed:0.85 green:0.25 blue:0.25 alpha:1] forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [x addTarget:g_helper action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:x];

    y = 52;
    mkToggleCard(CGRectMake(pad, y, cw, ch), @"🎯", DK_RED,   @"怪物自杀", @"全场怪物即死",  g_killOn,  g_helper, @selector(killSw:),  g_panel);
    mkToggleCard(CGRectMake(pad*2+cw, y, cw, ch), @"🛡️", DK_BLUE, @"无敌",     @"绝对无敌+满血", g_invOn,   g_helper, @selector(invSw:),   g_panel);
    y += ch + 8;
    mkToggleCard(CGRectMake(pad, y, cw, ch), @"⏱️", DK_GREEN, @"游戏加速", @"战斗整体变速",  g_speedOn, g_helper, @selector(speedSw:), g_panel);
    mkToggleCard(CGRectMake(pad*2+cw, y, cw, ch), @"🚫", DK_GOLD,  @"免广告",   @"跳过视频直发奖", g_noAdOn,  g_helper, @selector(noAdSw:),  g_panel);
    y += ch + 8;
    // 一键通关 (大按钮)
    mkGoCard(CGRectMake(pad, y, W - pad*2, 56), @"⚡", DK_GOLD, @"一键通关", g_helper, @selector(passTap), g_panel);
    y += 64;
    // 加速倍率步进
    mkStepCard(CGRectMake(pad, y, W - pad*2, 56), @"🧭", DK_BLUE, @"加速倍率", @"点 ± 调整 (开启加速后生效)",
               &g_spdVal, g_helper, @selector(spdDec), @selector(spdInc), g_panel);
    g_spdVal.text = [NSString stringWithFormat:@"%.1fx", g_speedMult];
    y += 64;
    // 经验
    mkStepCard(CGRectMake(pad, y, W - pad*2, 56), @"⚡", DK_GREEN, @"单次经验", @"点 ± 改量",
               &g_expVal, g_helper, @selector(expDec), @selector(expInc), g_panel);
    g_expVal.text = [NSString stringWithFormat:@"%d", g_expValue];
    y += 58;
    mkGoCard(CGRectMake(pad, y, W - pad*2, 48), @"＋", DK_GREEN, @"增加局内经验", g_helper, @selector(expGo), g_panel);
    y += 56;
    // 金币
    mkStepCard(CGRectMake(pad, y, W - pad*2, 56), @"🪙", DK_GOLD, @"单次金币", @"点 ± 改量",
               &g_goldVal, g_helper, @selector(goldDec), @selector(goldInc), g_panel);
    g_goldVal.text = [NSString stringWithFormat:@"%d", g_goldValue];
    y += 58;
    mkGoCard(CGRectMake(pad, y, W - pad*2, 48), @"＋", DK_GOLD, @"增加局内金币", g_helper, @selector(goldGo), g_panel);
    y += 56;
    mkLabel(@"弹壳战机 1.1.7 · 单机PvE · 昆哥儿", 9, UIFontWeightRegular,
            [UIColor colorWithRed:0.69 green:0.69 blue:0.73 alpha:1],
            CGRectMake(pad, y, W - pad*2, 14), g_panel).textAlignment = NSTextAlignmentCenter;
    g_panel.frame = CGRectMake(x, MIN(74, MAX(20, win.bounds.size.height - (y + 30))), W, y + 30);

    // 拖动面板
    g_panelPan = [[UIPanGestureRecognizer alloc] initWithTarget:g_helper action:@selector(panelPan:)];
    g_panelPan.delegate = g_helper;
    [g_panel addGestureRecognizer:g_panelPan];

    // 悬浮球 (58pt, 直接挂游戏 window 顶层 → 球外区域天然不挡触摸)
    g_ball = [UIButton buttonWithType:UIButtonTypeCustom];
    CGFloat bs = 58;
    g_ball.frame = CGRectMake(win.bounds.size.width - bs - 16, 150, bs, bs);
    g_ball.layer.cornerRadius = bs / 2;
    g_ball.backgroundColor = DK_TEAL;
    g_ball.layer.borderWidth = 2;
    g_ball.layer.borderColor = UIColor.whiteColor.CGColor;
    g_ball.layer.shadowColor = UIColor.blackColor.CGColor;
    g_ball.layer.shadowOpacity = 0.3; g_ball.layer.shadowOffset = CGSizeMake(0, 3); g_ball.layer.shadowRadius = 6;
    [g_ball setTitle:@"弹" forState:UIControlStateNormal];
    [g_ball setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    g_ball.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [g_ball addTarget:g_helper action:@selector(ballTapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *bp = [[UIPanGestureRecognizer alloc] initWithTarget:g_helper action:@selector(ballPan:)];
    bp.delegate = g_helper;
    [g_ball addGestureRecognizer:bp];
    [win addSubview:g_ball];
    L("UI ✓ 面板+悬浮球已挂载 (win=%.0fx%.0f)", win.bounds.size.width, win.bounds.size.height);
}

static void dk_ensure_overlay(void) {
    UIWindow *win = dk_game_window();
    if (!win) return;
    if (!g_ball) { dk_build_ui(); return; }
    if (g_ball.superview != win) [win addSubview:g_ball];
    if (g_panel.superview != win) [win addSubview:g_panel];
    if (win.subviews.lastObject != g_panel && !g_panel.hidden) [win bringSubviewToFront:g_panel];
    if (win.subviews.lastObject != g_ball && g_panel.hidden) [win bringSubviewToFront:g_ball];
    if (win.subviews.lastObject != g_ball && !g_panel.hidden) [win bringSubviewToFront:g_ball];
}

// ───────────────────── 安装 / 入口 ─────────────────────
static void dk_install_all(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = paths.firstObject;
    if (doc && [NSFileManager.defaultManager fileExistsAtPath:
                [doc stringByAppendingPathComponent:@"dkzj3_off"]]) {
        L("dkzj3_off 存在 → 禁用"); return;
    }
    dk_guard_install();
    if (!find_unity_base()) { L("X UnityFramework 未找到"); return; }
    L("== DKZJ v3.0 启动 — unity base=%p text=0x%llx slide=%d",
      (void *)g_unityBase, g_textSize, g_slide);
    dk_syms_load();
    if (!ic_init()) { L("X il2cpp 初始化失败 → 禁用"); return; }

    // 阶段A: 后台线程解析 (HybridCLR 热更类需 il2cpp_thread_attach)
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ic_ensure_thread();
        for (int i = 0; i < 240; i++) {          // 最多 4 分钟 (热更可能较晚加载)
            if (resolve_try()) break;
            usleep(1000 * 1000);
        }
        if (!g_parsed) L("A X 解析超时 (热更未加载?)");
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_statusSub)
                g_statusSub.text = g_parsed ? @"已就绪，进入关卡后生效" : @"解析超时 (请重进游戏)";
        });
    });

    // UI + 主循环
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        dk_build_ui();
        [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(__unused NSTimer *t){
            combat_tick();
            static int k = 0;
            if (++k % 10 == 0) dk_ensure_overlay();
        }];
    });
    L("install done — 点球开面板 (7 功能)");
}

__attribute__((constructor))
static void dkzj_ctor(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    // 只对目标包注入 (主包 / 分发包名均兼容)
    if (![bid hasPrefix:@"com.survivor.ace"]) {
        L("ctor: bundle=%@ ≠ com.survivor.ace* → skip", bid);
        return;
    }
    L("ctor: bundle=%@ → 等待 UnityFramework", bid);
    __block int tries = 0;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_global_queue(0, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 500 * NSEC_PER_MSEC, 0);
    dispatch_source_set_event_handler(timer, ^{
        tries++;
        if (find_unity_base()) {
            dispatch_source_cancel(timer);
            dk_install_all();
        } else if (tries > 120) {
            dispatch_source_cancel(timer);
            L("ctor: UnityFramework 超时未加载");
        }
    });
    dispatch_resume(timer);
}
