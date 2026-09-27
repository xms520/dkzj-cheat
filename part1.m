//
//  DKZJ.m — 弹壳战机 1.1.7 (com.survivor.acecn) 悬浮助手 v3.1
//  ═══════════════════════════════════════════════════════════════════════
//  v3.1 修正 (真机 .log 判决: v3.0 在 il2cpp_domain_get_assemblies 首次调用处闪退)
//   ① 类解析从【后台线程】搬到【主线程分步状态机】—— il2cpp Assembly 惰性初始化
//      与游戏主线程存在竞态, 后台线程首调必崩 (MXYZF v1.7 同源教训)
//   ② 就绪判据改为 il2cpp_domain_get() 非 NULL (il2cpp_init 完成即置位, 零副作用),
//      而非直接调 get_assemblies 试探
//   ③ 删除 LC_SYMTAB nlist 全表扫描 (LC_SYMTAB 字段被加固改写 → nl 指针落在 __DATA
//      → 野指针读; dlsym 已实证可用 241 个 il2cpp 导出, 无需该路径)
//   ④ 崩溃自动熔断: 连续启动 3 次未进战斗 → 写 dkzj3_off 自我禁用 (保护设备)
//   ⑤ 日志格式 %@ → %s
//
//  引擎: Unity 2022.3.62f2 IL2CPP + HybridCLR 热更 (HotFix.dll / HotFixBattle.dll)
//  ⚠️ 单机 PvE 专用; 联机命令上行服务器, 勿开
//  ═══════════════════════════════════════════════════════════════════════

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
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
#include <unistd.h>

// ───────────────────── 日志 ─────────────────────
static NSString *dk_doc_path(void);
static void L(const char *fmt, ...) {
    char msg[768];
    va_list ap; va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    NSString *doc = dk_doc_path();
    if (doc) {
        NSString *p = [doc stringByAppendingPathComponent:@"dkzj3.log"];
        FILE *f = fopen(p.fileSystemRepresentation, "a");
        if (f) { fprintf(f, "%s\n", msg); fclose(f); }
    }
    NSLog(@"[DKZJ3] %s", msg);
}
static NSString *dk_doc_path(void) {
    static NSString *c = nil;
    if (!c) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        c = paths.count ? paths.firstObject : nil;
    }
    return c;
}

// ───────────────────── 功能开关 ─────────────────────
static BOOL  g_killOn   = NO;
static BOOL  g_invOn    = NO;
static BOOL  g_speedOn  = NO;
static BOOL  g_noAdOn   = NO;
static BOOL  g_speedWasOn = NO;
static float g_speedMult = 2.0f;
static int   g_expValue  = 1000;
static int   g_goldValue = 1000;
static BOOL  g_inBattle = NO;

static UIButton *g_ball = nil;
static UIView   *g_panel = nil;
static UIPanGestureRecognizer *g_panelPan = nil;
static UILabel  *g_statusSub = nil;
static UILabel  *g_expVal = nil, *g_goldVal = nil, *g_spdVal = nil;

// ───────────────────── SIGSEGV 安全网 ─────────────────────
static volatile sig_atomic_t g_guardActive = 0;
static volatile sig_atomic_t g_guardDepth  = 0;
static sigjmp_buf g_guardEnv;

static void dk_segv_handler(int sig) {
    if (g_guardActive) { g_guardActive = 0; g_guardDepth = 0; siglongjmp(g_guardEnv, 1); }
    signal(sig, SIG_DFL);
    raise(sig);
}
static void dk_guard_install(void) {
    struct sigaction sa; memset(&sa, 0, sizeof(sa));
    sa.sa_handler = dk_segv_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
}
#define DK_GUARD_BEGIN() (g_guardDepth++, g_guardActive = 1, sigsetjmp(g_guardEnv, 1))
#define DK_GUARD_END()   do { if (g_guardDepth > 0) g_guardDepth--; if (g_guardDepth == 0) g_guardActive = 0; } while (0)

// ───────────────────── Unity 基址 ─────────────────────
static uint64_t g_unityBase = 0;
static uint64_t g_textSize  = 0;
static int      g_slide     = 0;
static int      g_sdkVer    = 0;

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

static int dk_ptr_executable(uintptr_t a) {
    if (!a) return 0;
    return (a >= g_unityBase && a < g_unityBase + g_textSize) ? 1 : 0;
}

// ───────────────────── 符号解析: 只走 dlsym ─────────────────────
// ⚠️ v3.1: 删除 LC_SYMTAB 扫描。该二进制 LC_SYMTAB 的 symoff/nsyms 被加固改写
//    (symoff 指向 __DATA 段), 全表扫描 = 野指针读 → 不可控崩溃。
//    1.1.7 实证: LC_DYLD_EXPORTS_TRIE @0xabbbc00 有效, 241 个 il2cpp_* 全部可 dlsym。
static int g_dlsymHits = 0;
static void *dk_sym_find(const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (!p && name[0] == '_') p = dlsym(RTLD_DEFAULT, name + 1);
    if (!p && name[0] != '_') {
        char buf[128]; snprintf(buf, sizeof(buf), "_%s", name);
        p = dlsym(RTLD_DEFAULT, buf);
    }
    if (p) g_dlsymHits++;
    return p;
}
