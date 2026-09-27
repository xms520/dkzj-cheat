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

// ───────────────────── il2cpp C API (dlsym) ─────────────────────
typedef void* Il2CppDomain;
typedef void* Il2CppImage;
typedef void* Il2CppClass;
typedef void* Il2CppMethodInfo;
typedef void* Il2CppFieldInfo;
typedef void* Il2CppObject;

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
    Il2CppObject*     (*string_new)(const char *);
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
    void*             (*class_get_type)(Il2CppClass *);
    void*             (*type_get_object)(void *);
} dk_il2cpp_t;

static dk_il2cpp_t I;
static BOOL ic_ready = NO;

static BOOL ic_init(void) {
    if (ic_ready) return YES;
    if (!g_unityBase) { L("ic: unity base 未就绪"); return NO; }
    memset(&I, 0, sizeof(I));
    I.domain_get                  = (void*)dk_sym_find("il2cpp_domain_get");
    I.domain_get_assemblies       = (void*)dk_sym_find("il2cpp_domain_get_assemblies");
    I.assembly_get_image          = (void*)dk_sym_find("il2cpp_assembly_get_image");
    I.class_from_name             = (void*)dk_sym_find("il2cpp_class_from_name");
    I.class_get_method_from_name  = (void*)dk_sym_find("il2cpp_class_get_method_from_name");
    I.class_get_methods           = (void*)dk_sym_find("il2cpp_class_get_methods");
    I.class_get_field_from_name   = (void*)dk_sym_find("il2cpp_class_get_field_from_name");
    I.class_get_fields            = (void*)dk_sym_find("il2cpp_class_get_fields");
    I.class_get_parent            = (void*)dk_sym_find("il2cpp_class_get_parent");
    I.class_get_name              = (void*)dk_sym_find("il2cpp_class_get_name");
    I.class_get_namespace         = (void*)dk_sym_find("il2cpp_class_get_namespace");
    I.method_get_name             = (void*)dk_sym_find("il2cpp_method_get_name");
    I.method_get_param_count      = (void*)dk_sym_find("il2cpp_method_get_param_count");
    I.field_get_name              = (void*)dk_sym_find("il2cpp_field_get_name");
    I.field_get_offset            = (void*)dk_sym_find("il2cpp_field_get_offset");
    I.field_get_value             = (void*)dk_sym_find("il2cpp_field_get_value");
    I.field_set_value             = (void*)dk_sym_find("il2cpp_field_set_value");
    I.field_static_get_value      = (void*)dk_sym_find("il2cpp_field_static_get_value");
    I.field_static_set_value      = (void*)dk_sym_find("il2cpp_field_static_set_value");
    I.runtime_invoke              = (void*)dk_sym_find("il2cpp_runtime_invoke");
    I.string_new                  = (void*)dk_sym_find("il2cpp_string_new");
    I.object_new                  = (void*)dk_sym_find("il2cpp_object_new");
    I.thread_attach               = (void*)dk_sym_find("il2cpp_thread_attach");
    I.thread_current              = (void*)dk_sym_find("il2cpp_thread_current");
    I.gc_disable                  = (void*)dk_sym_find("il2cpp_gc_disable");
    I.object_get_class            = (void*)dk_sym_find("il2cpp_object_get_class");
    I.class_is_assignable_from    = (void*)dk_sym_find("il2cpp_class_is_assignable_from");
    I.value_box                   = (void*)dk_sym_find("il2cpp_value_box");
    I.class_init                  = (void*)dk_sym_find("il2cpp_runtime_class_init");
    I.image_get_name              = (void*)dk_sym_find("il2cpp_image_get_name");
    I.image_get_class_count       = (void*)dk_sym_find("il2cpp_image_get_class_count");
    I.image_get_class             = (void*)dk_sym_find("il2cpp_image_get_class");
    I.class_get_type              = (void*)dk_sym_find("il2cpp_class_get_type");
    I.type_get_object             = (void*)dk_sym_find("il2cpp_type_get_object");
    int miss = 0;
    struct { const char *n; void *p; } req[] = {
        {"domain_get", I.domain_get},
        {"domain_get_assemblies", I.domain_get_assemblies},
        {"assembly_get_image", I.assembly_get_image},
        {"class_from_name", I.class_from_name},
        {"class_get_method_from_name", I.class_get_method_from_name},
        {"runtime_invoke", I.runtime_invoke},
        {"object_get_class", I.object_get_class},
        {"class_get_field_from_name", I.class_get_field_from_name},
    };
    for (size_t i = 0; i < sizeof(req)/sizeof(req[0]); i++) {
        uintptr_t a = (uintptr_t)req[i].p;
        if (!a) { miss++; L("ic: MISSING %s", req[i].n); }
        else if (!dk_ptr_executable(a)) L("ic: ⚠️ OUT-OF-TEXT %s=%p (符号来自其他镜像, 可用)", req[i].n, req[i].p);
    }
    if (miss) { L("ic: %d 必需 API 缺失 → 禁用", miss); return NO; }
    ic_ready = YES;
    L("ic ✓ il2cpp C API 就绪 (%d 符号, domain_get=%p invoke=%p)",
      g_dlsymHits, I.domain_get, I.runtime_invoke);
    return YES;
}

// 域就绪探测: il2cpp_init 完成后 domain 即非 NULL (零副作用, 不触发 Assembly 惰性初始化)
static BOOL ic_domain_ready(void) {
    if (!ic_ready || !I.domain_get) return NO;
    void *d = NULL;
    if (DK_GUARD_BEGIN() == 0) d = I.domain_get();
    DK_GUARD_END();
    return d ? YES : NO;
}

// 方法调用包装
static Il2CppObject *ic_call(void *mi, void *obj, void **args) {
    if (!mi || !I.runtime_invoke) return NULL;
    void *exc = NULL;
    return I.runtime_invoke(mi, obj, args, &exc);
}
static int32_t ic_call_i32(void *mi, void *obj, int32_t arg) {
    void *args[1] = { &arg };
    Il2CppObject *r = ic_call(mi, obj, args);
    return r ? *(int32_t *)((uint8_t *)r + 0x10) : 0;
}
static int64_t ic_call_i64(void *mi, void *obj, int64_t arg) {
    void *args[1] = { &arg };
    Il2CppObject *r = ic_call(mi, obj, args);
    return r ? *(int64_t *)((uint8_t *)r + 0x10) : 0;
}

// Il2CppArray: [klass 0x00][monitor 0x08][bounds 0x10][max_length 0x18][data 0x20]
static int32_t arr_len(void *arr) { return arr ? *(int32_t *)((uint8_t *)arr + 0x18) : 0; }
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

// ── 世界实例获取 ──
static void *ic_find_image(const char *want) {
    if (!ic_ready || !ic_domain_ready()) return NULL;
    if (!I.domain_get_assemblies || !I.assembly_get_image) return NULL;
    void *r = NULL;
    if (DK_GUARD_BEGIN() == 0) {
        size_t n = 0;
        void **asms = (void **)I.domain_get_assemblies(I.domain_get(), &n);
        if (asms && n < 4096) {
            for (size_t i = 0; i < n; i++) {
                if (!asms[i]) continue;
                Il2CppImage img = I.assembly_get_image(asms[i]);
                if (!img) continue;
                const char *nm = I.image_get_name ? I.image_get_name(img) : NULL;
                if (nm && !strcmp(nm, want)) { r = img; break; }
            }
        }
    }
    DK_GUARD_END();
    return r;
}


// ───────────────────── 类/方法解析: 主线程分步状态机 ─────────────────────
// ⚠️ 关键教训 (v3.0 真机 .log):
//   il2cpp_domain_get_assemblies / class_from_name 从【非主线程】首次调用 → SIGSEGV。
//   而 SIGSEGV handler 里的 siglongjmp 是【线程绑定】的: 后台线程 longjmp 到主线程
//   sigsetjmp 环境 = 未定义行为 → 二次崩溃, guard 完全失效 (日志实证: 直接重启)。
//   → 全部 il2cpp 反射调用必须只在【主线程】执行, 且每 tick 只走一小步。
//   另: il2cpp_init 完成后 il2cpp_domain_get() 即非 NULL (零副作用) → 用它做就绪判据,
//       不主动调 get_assemblies 试探。

static Il2CppImage g_imgHF  = NULL;
static Il2CppImage g_imgHFB = NULL;
static Il2CppImage g_imgAD  = NULL;
static Il2CppImage g_imgCOR = NULL;

static Il2CppClass *k_BattleGame, *k_WorldBattle, *k_BLW, *k_Ctx;
static Il2CppClass *k_EM, *k_Char, *k_Hero, *k_TDD, *k_BattleMgr, *k_BattleData;
static Il2CppClass *k_ADMgr, *k_AdData, *k_I64, *k_Ad_Local;
static Il2CppClass *k_Game, *k_GameMgr, *k_UObject;

static void *m_BG_getWorld, *m_WB_getLogicWorld, *m_WB_StopTime, *m_WB_ResetTime, *m_WB_SetLevel;
static void *m_Ctx_getEntity, *m_Ctx_getBattleMgr, *m_Ctx_getBattleData;
static void *m_EM_GetEntityValues, *m_EM_GetAllPlayer, *m_EM_GetPlayer, *m_EM_EnemyCommitSuicide;
static void *m_Char_SetHp, *m_Char_GetHp, *m_Char_OnDeath, *m_Char_UpdateHp;
static void *m_Char_getIsDead, *m_Char_Suicide;
static void *m_Char_AddAbsInv, *m_Char_RemoveAbsInv;
static void *m_Char_AddStatus, *m_Char_RemoveStatus;
static void *m_Char_getCurrentHp, *m_Char_setCurrentHp;
static void *m_BM_AddExpAndGold, *m_BM_OnMissionClear, *m_BM_OnChapterEnd;
static void *m_BD_AddUserExp, *m_BD_AddDropGold, *m_BD_AddWaveGold, *m_BD_AddDiamond;
static void *m_AD_CheckAndPlayVideo;
static void *m_Ad_Show0;
static void *m_GM_SetTimeScale, *m_Game_SetTimeScale;
static void *m_UO_FindObjectOfType;

static int32_t off_CurLogicWorld = -1;
static int32_t off_BLW_worldCtx   = -1;
static int32_t off_Ctx_gameSpeed  = -1;
static int32_t off_World_timeScale= -1;
static int32_t off_AD_onClose     = -1;

static BOOL g_parsed = NO;
static void *g_worldCache = NULL;

static int32_t foff(Il2CppClass *k, const char *name) {
    if (!k || !I.class_get_field_from_name || !I.field_get_offset) return -1;
    int32_t r = -1;
    if (DK_GUARD_BEGIN() == 0) {
        Il2CppFieldInfo *f = I.class_get_field_from_name(k, name);
        if (f) r = (int32_t)I.field_get_offset(f);
    }
    DK_GUARD_END();
    return r;
}

static void *mof(Il2CppClass *k, const char *name, int argc) {
    if (!k || !I.class_get_method_from_name) return NULL;
    void *r = NULL;
    if (DK_GUARD_BEGIN() == 0) r = I.class_get_method_from_name(k, name, argc);
    DK_GUARD_END();
    return r;
}

static Il2CppClass *cn(Il2CppImage img, const char *ns, const char *name) {
    if (!img || !I.class_from_name) return NULL;
    Il2CppClass *r = NULL;
    if (DK_GUARD_BEGIN() == 0) r = I.class_from_name(img, ns, name);
    DK_GUARD_END();
    return r;
}

// ── 分步状态机 ──
enum { RS_WAIT_DOMAIN = 0, RS_HF, RS_HFB, RS_AD, RS_COR, RS_C1, RS_C2, RS_C3,
       RS_M1, RS_M2, RS_M3, RS_M4, RS_OFF, RS_DONE, RS_FAIL };
static int g_rs = RS_WAIT_DOMAIN;
static int g_rsTick = 0;
static int g_rsFails = 0;

static void rs_log(const char *stage, BOOL ok) {
    L("A[%s] %s", stage, ok ? "✓" : "✗");
}

// 每个 tick 推进一小步 (每步最多 1~4 次安全调用)
static void resolve_step(void) {
    if (g_parsed || g_rs == RS_DONE || g_rs == RS_FAIL) return;
    if (++g_rsTick < 3) return;      // 每 3 个 tick (≈1.2s) 走一步
    g_rsTick = 0;

    switch (g_rs) {
    case RS_WAIT_DOMAIN:
        if (ic_domain_ready()) { g_rs = RS_HF; L("A[domain] ✓ il2cpp 域就绪"); }
        else if (++g_rsFails > 400) { g_rs = RS_FAIL; L("A[domain] ✗ 超时"); }
        return;
    case RS_HF:
        g_imgHF = ic_find_image("HotFix.dll");
        rs_log("HotFix.dll", g_imgHF != NULL);
        if (g_imgHF) { g_rs = RS_HFB; g_rsFails = 0; }
        else if (++g_rsFails > 200) { g_rs = RS_FAIL; }
        return;
    case RS_HFB:
        g_imgHFB = ic_find_image("HotFixBattle.dll");
        rs_log("HotFixBattle.dll", g_imgHFB != NULL);
        if (g_imgHFB) { g_rs = RS_AD; g_rsFails = 0; }
        else if (++g_rsFails > 200) { g_rs = RS_FAIL; }
        return;
    case RS_AD:
        g_imgAD = ic_find_image("GorillaAd.Runtime.dll");
        L("A[GorillaAd] %s", g_imgAD ? "✓" : "✗ (可缺)");
        g_rs = RS_COR; return;
    case RS_COR:
        g_imgCOR = ic_find_image("mscorlib.dll");
        L("A[mscorlib] %s", g_imgCOR ? "✓" : "✗ (可缺)");
        g_rs = RS_C1; return;
    case RS_C1:
        k_BattleGame  = cn(g_imgHF, "HotFix", "BattleGame");
        k_WorldBattle = cn(g_imgHF, "HotFix", "WorldBattle");
        k_BLW         = cn(g_imgHFB, "HotFix.BattleLogic", "BattleLogicWorld");
        k_Ctx         = cn(g_imgHFB, "HotFix.BattleLogic", "BattleWorldContext");
        L("A[C1] BG=%p WB=%p BLW=%p CTX=%p", k_BattleGame, k_WorldBattle, k_BLW, k_Ctx);
        if (k_BattleGame && k_WorldBattle && k_Ctx) g_rs = RS_C2;
        else if (++g_rsFails > 60) { g_rs = RS_FAIL; L("A[C1] ✗ 类缺失"); }
        return;
    case RS_C2:
        k_EM   = cn(g_imgHFB, "HotFix.BattleLogic", "EntityManager");
        k_Char = cn(g_imgHFB, "HotFix.BattleLogic", "EntityCharacter");
        k_Hero = cn(g_imgHFB, "HotFix.BattleLogic", "EntityHero");
        k_TDD  = cn(g_imgHFB, "HotFix.BattleLogic", "TakeDamageData");
        L("A[C2] EM=%p Char=%p Hero=%p TDD=%p", k_EM, k_Char, k_Hero, k_TDD);
        if (k_Char) g_rs = RS_C3; else if (++g_rsFails > 60) g_rs = RS_FAIL;
        return;
    case RS_C3:
        k_BattleMgr  = cn(g_imgHFB, "HotFix.BattleLogic", "BattleManager");
        k_BattleData = cn(g_imgHFB, "HotFix.BattleLogic", "BattleData");
        k_ADMgr      = cn(g_imgHF, "HotFix", "ADModuleMgr");
        k_AdData     = cn(g_imgHF, "HotFix", "AdData");
        k_Game       = cn(g_imgHF, "HotFix", "Game");
        k_GameMgr    = cn(g_imgHF, "HotFix", "GameManager");
        k_I64        = cn(g_imgCOR, "System", "Int64");
        L("A[C3] BM=%p BD=%p ADMgr=%p Game=%p GM=%p I64=%p",
          k_BattleMgr, k_BattleData, k_ADMgr, k_Game, k_GameMgr, k_I64);
        g_rs = RS_M1; return;
    case RS_M1:
        m_BG_getWorld      = mof(k_BattleGame, "get_World", 0);
        m_WB_getLogicWorld = mof(k_WorldBattle, "get_LogicWorld", 0);
        m_Ctx_getEntity    = mof(k_Ctx, "get_Entity", 0);
        m_Ctx_getBattleMgr = mof(k_Ctx, "get_BattleMgr", 0);
        m_Ctx_getBattleData= mof(k_Ctx, "get_BattleData", 0);
        L("A[M1] getWorld=%p logicWorld=%p ctxEntity=%p", m_BG_getWorld, m_WB_getLogicWorld, m_Ctx_getEntity);
        g_rs = RS_M2; return;
    case RS_M2:
        if (k_EM) {
            m_EM_GetEntityValues    = mof(k_EM, "GetEntityValues", 0);
            m_EM_GetAllPlayer       = mof(k_EM, "GetAllPlayer", 0);
            m_EM_GetPlayer          = mof(k_EM, "GetPlayer", 1);
            m_EM_EnemyCommitSuicide = mof(k_EM, "EnemyCommitSuicide", 2);
        }
        if (k_Char) {
            m_Char_SetHp        = mof(k_Char, "SetHp", 1);
            m_Char_GetHp        = mof(k_Char, "GetHp", 0);
            m_Char_OnDeath      = mof(k_Char, "OnDeath", 1);
            m_Char_getIsDead    = mof(k_Char, "get_IsDead", 0);
            m_Char_Suicide      = mof(k_Char, "Suicide", 1);
            m_Char_AddAbsInv    = mof(k_Char, "AddAbsoluteInvincibility", 0);
            m_Char_RemoveAbsInv = mof(k_Char, "RemoveAbsoluteInvincibility", 0);
            m_Char_AddStatus    = mof(k_Char, "AddCharacterStatus", 1);
            m_Char_getCurrentHp = mof(k_Char, "get_CurrentHp", 0);
            m_Char_setCurrentHp = mof(k_Char, "set_CurrentHp", 1);
        }
        L("A[M2] vals=%p allPlayer=%p suicide=%p SetHp=%p OnDeath=%p absInv=%p status=%p",
          m_EM_GetEntityValues, m_EM_GetAllPlayer, m_EM_EnemyCommitSuicide,
          m_Char_SetHp, m_Char_OnDeath, m_Char_AddAbsInv, m_Char_AddStatus);
        g_rs = RS_M3; return;
    case RS_M3:
        if (k_BattleMgr) {
            m_BM_AddExpAndGold  = mof(k_BattleMgr, "AddExpAndGold", 0);
            m_BM_OnMissionClear = mof(k_BattleMgr, "OnMissionClear", 0);
            m_BM_OnChapterEnd   = mof(k_BattleMgr, "OnChapterEnd", 0);
        }
        if (k_BattleData) {
            m_BD_AddUserExp   = mof(k_BattleData, "AddUserExp", 1);
            m_BD_AddDropGold  = mof(k_BattleData, "AddDropGold", 1);
            m_BD_AddWaveGold  = mof(k_BattleData, "AddWaveGold", 1);
        }
        L("A[M3] expAndGold=%p missionClear=%p AddUserExp=%p AddDropGold=%p",
          m_BM_AddExpAndGold, m_BM_OnMissionClear, m_BD_AddUserExp, m_BD_AddDropGold);
        g_rs = RS_M4; return;
    case RS_M4:
        if (k_ADMgr) {
            m_AD_CheckAndPlayVideo = mof(k_ADMgr, "CheckAndPlayVideo", 2);
            off_AD_onClose = foff(k_ADMgr, "_onClose");
        }
        if (k_GameMgr) m_GM_SetTimeScale   = mof(k_GameMgr, "SetTimeScale", 1);
        if (k_Game)    m_Game_SetTimeScale = mof(k_Game, "SetTimeScale", 1);
        if (k_Ad_Local) m_Ad_Show0 = mof(k_Ad_Local, "Show", 0);
        L("A[M4] adPlay=%p adOnClose@0x%x GM=%p Game=%p adShow0=%p",
          m_AD_CheckAndPlayVideo, off_AD_onClose, m_GM_SetTimeScale, m_Game_SetTimeScale, m_Ad_Show0);
        g_rs = RS_OFF; return;
    case RS_OFF:
        off_CurLogicWorld   = foff(k_WorldBattle, "CurLogicWorld");
        off_BLW_worldCtx    = foff(k_BLW, "_worldContext");
        off_Ctx_gameSpeed   = foff(k_Ctx, "gameSpeed");
        off_World_timeScale = foff(k_WorldBattle, "_curTimeScale");
        if (g_imgAD && !k_Ad_Local)
            k_Ad_Local = cn(g_imgAD, "GorillaAd.Runtime", "LocalRewardedVideoAd");
        if (k_Ad_Local) m_Ad_Show0 = mof(k_Ad_Local, "Show", 0);
        L("A[OFF] curLogicWorld=0x%x worldCtx=0x%x gameSpeed=0x%x timeScale=0x%x",
          off_CurLogicWorld, off_BLW_worldCtx, off_Ctx_gameSpeed, off_World_timeScale);
        // 入口可用性判定
        if (!m_BG_getWorld && off_CurLogicWorld <= 0) {
            L("A ✗ 无可用世界入口 → 功能不可用");
            g_rs = RS_FAIL; return;
        }
        g_parsed = YES;
        g_rs = RS_DONE;
        L("A ✓✓ 解析完成 — 进入关卡后功能生效");
        {
            NSString *doc = dk_doc_path();
            if (doc) {
                NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
                [ud setInteger:0 forKey:@"dk3_crashStreak"];
                [ud synchronize];
            }
        }
        return;
    case RS_DONE: case RS_FAIL: default: return;
    }
}

static void *get_world(void) {
    if (!g_parsed) return NULL;
    if (m_BG_getWorld) {
        void *w = NULL;
        if (DK_GUARD_BEGIN() == 0) w = ic_call(m_BG_getWorld, NULL, NULL);
        DK_GUARD_END();
        if (w) { g_worldCache = w; return w; }
    }
    return g_worldCache;
}

static void *get_logic_world(void *world) {
    if (!world) return NULL;
    if (m_WB_getLogicWorld) {
        void *b = NULL;
        if (DK_GUARD_BEGIN() == 0) b = ic_call(m_WB_getLogicWorld, world, NULL);
        DK_GUARD_END();
        if (b) return b;
    }
    if (off_CurLogicWorld > 0) {
        void *b = *(void **)((uint8_t *)world + off_CurLogicWorld);
        if (b) return b;
    }
    return NULL;
}

static void *get_ctx(void) {
    void *world = get_world();
    if (!world) return NULL;
    void *blw = get_logic_world(world);
    if (!blw || off_BLW_worldCtx <= 0) return NULL;
    return *(void **)((uint8_t *)blw + off_BLW_worldCtx);
}

static void *ctx_entity(void *ctx)     { return (ctx && m_Ctx_getEntity)     ? ic_call(m_Ctx_getEntity, ctx, NULL)     : NULL; }
static void *ctx_battlemgr(void *ctx)  { return (ctx && m_Ctx_getBattleMgr)  ? ic_call(m_Ctx_getBattleMgr, ctx, NULL)  : NULL; }
static void *ctx_battledata(void *ctx) { return (ctx && m_Ctx_getBattleData) ? ic_call(m_Ctx_getBattleData, ctx, NULL) : NULL; }

static BOOL battle_alive(void) {
    void *w = get_world();
    if (!w) return NO;
    if (!get_logic_world(w)) return NO;
    return get_ctx() ? YES : NO;
}

// 虚方法: 按运行时类解析
static void *vmi(void *obj, const char *name, int argc) {
    if (!obj || !I.object_get_class || !I.class_get_method_from_name) return NULL;
    Il2CppClass *rc = NULL;
    if (DK_GUARD_BEGIN() == 0) rc = (Il2CppClass *)I.object_get_class(obj);
    DK_GUARD_END();
    if (!rc) return NULL;
    void *m = mof(rc, name, argc);
    if (m) return m;
    Il2CppClass *c = rc;
    for (int i = 0; i < 8 && c; i++) {
        c = I.class_get_parent ? (Il2CppClass *)I.class_get_parent(c) : NULL;
        if (!c) break;
        m = mof(c, name, argc);
        if (m) return m;
    }
    return NULL;
}

static BOOL is_inst_of(void *obj, Il2CppClass *k) {
    if (!obj || !k || !I.object_get_class || !I.class_is_assignable_from) return NO;
    BOOL r = NO;
    if (DK_GUARD_BEGIN() == 0) {
        Il2CppClass *rc = (Il2CppClass *)I.object_get_class(obj);
        if (rc) r = I.class_is_assignable_from(k, rc) ? YES : NO;
    }
    DK_GUARD_END();
    return r;
}

// ───────────────────── 通用 MethodInfo 热替换 (数据段, 零 __TEXT patch) ─────────────────────
typedef struct {
    uintptr_t  *slot;
    uintptr_t   orig;
    void       *mi;
    const char *tag;
    int         hits;
} dk_hook_rec_t;

static dk_hook_rec_t g_hooks[8];
static int g_hookN = 0;

static int ptr_is_cstr(uintptr_t v, const char *want) {
    if (!v || !want || v < 0x1000) return 0;
    int ok = 0;
    if (DK_GUARD_BEGIN() == 0) {
        const char *s = (const char *)v;
        if (s == want) ok = 1;
        else if (strcmp(s, want) == 0) ok = 1;
    }
    DK_GUARD_END();
    return ok;
}

static uintptr_t *find_methodptr_slot(void *mi, const char *tag) {
    if (!mi) return NULL;
    const char *want = (I.method_get_name) ? I.method_get_name(mi) : NULL;
    uint8_t *p = (uint8_t *)mi;
    int nameOff = -1, ptrOff = -1;
    if (DK_GUARD_BEGIN() == 0) {
        for (int off = 0; off <= 96; off += 8) {
            uintptr_t v = *(uintptr_t *)(p + off);
            if (!v) continue;
            if (nameOff < 0 && want && ptr_is_cstr(v, want)) { nameOff = off; continue; }
            if (ptrOff < 0 && dk_ptr_executable(v)) ptrOff = off;
        }
    }
    DK_GUARD_END();
    if (ptrOff < 0) { L("hook[%s]: methodPointer 未定位 (nameOff=%d)", tag, nameOff); return NULL; }
    if (nameOff < 0 && want) L("hook[%s]: ⚠️ name 未命中 methodPointer@%d", tag, ptrOff);
    else L("hook[%s]: name@%d methodPointer@%d (%s)", tag, nameOff, ptrOff, want ? want : "?");
    return (uintptr_t *)(p + ptrOff);
}

static void *dk_hook_method(void *mi, void *replacement, const char *tag) {
    if (!mi || !replacement || g_hookN >= 8) return NULL;
    uintptr_t *slot = find_methodptr_slot(mi, tag);
    if (!slot) return NULL;
    vm_address_t pg = (vm_address_t)((uintptr_t)slot & ~(uintptr_t)(vm_page_size - 1));
    kern_return_t kr = vm_protect(mach_task_self(), pg, vm_page_size, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) L("hook[%s]: vm_protect rwx kr=%d", tag, kr);
    g_hooks[g_hookN].slot = slot;
    g_hooks[g_hookN].orig = *slot;
    g_hooks[g_hookN].mi   = mi;
    g_hooks[g_hookN].tag  = tag;
    g_hooks[g_hookN].hits = 0;
    *slot = (uintptr_t)replacement;
    L("hook[%s]: 安装 %p → %p (slot=%p)", tag, (void *)g_hooks[g_hookN].orig, replacement, slot);
    g_hookN++;
    return slot;
}

static void dk_unhook_all(void) {
    for (int i = 0; i < g_hookN; i++)
        if (g_hooks[i].slot) *g_hooks[i].slot = g_hooks[i].orig;
    if (g_hookN) L("hook: 还原 %d 个", g_hookN);
    g_hookN = 0;
}

// ───────────────────── ⑤ 免广告 ─────────────────────
static int   g_adHooked = 0;
static void *g_ad_mp_slot = NULL;

static int looks_like_delegate(void *obj) {
    if (!obj || !I.object_get_class || !I.class_get_name) return 0;
    Il2CppClass *k = (Il2CppClass *)I.object_get_class(obj);
    if (!k) return 0;
    const char *nm = I.class_get_name(k);
    if (nm && (strstr(nm, "Action") || strstr(nm, "Func") || strstr(nm, "Callback")
        || strstr(nm, "Delegate") || strstr(nm, "<>") || strstr(nm, "Predicate"))) return 1;
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

static void ad_replacement_2(void *self, void *a1, void *a2) {
    if (g_hookN > 0) g_hooks[0].hits++;
    static int l = 0;
    if (l++ < 6) L("⑤ noAd: 拦截 CheckAndPlayVideo(self=%p a1=%p a2=%p)", self, a1, a2);
    int fired = 0;
    if (a1 && looks_like_delegate(a1)) fired += delegate_invoke(a1);
    if (a2 && looks_like_delegate(a2)) fired += delegate_invoke(a2);
    if (!fired && self && off_AD_onClose > 0) {
        void *d = *(void **)((uint8_t *)self + off_AD_onClose);
        if (d) fired += delegate_invoke(d);
    }
    if (l <= 6) L("⑤ noAd: 发奖回调 %d 次", fired);
}

static void ad_replacement_show0(void *self) {
    if (g_hookN > 1) g_hooks[1].hits++;
    static int l = 0;
    if (l++ < 6) L("⑤ noAd: 拦截 LocalRewardedVideoAd.Show(self=%p)", self);
    const char *fns[] = { "OnRewarded", "OnClosed", "OnShowSuccess" };
    int fired = 0;
    for (int i = 0; i < 3; i++) {
        Il2CppClass *rc = I.object_get_class ? (Il2CppClass *)I.object_get_class(self) : NULL;
        if (!rc) break;
        int32_t off = foff(rc, fns[i]);
        if (off > 0) {
            void *d = *(void **)((uint8_t *)self + off);
            if (d && looks_like_delegate(d)) fired += delegate_invoke(d);
        }
    }
    if (l <= 6) L("⑤ noAd: LocalShow 发奖 %d 次", fired);
}

static void ad_hook_install(void) {
    if (g_adHooked || !g_parsed) return;
    if (m_AD_CheckAndPlayVideo) {
        void *s = dk_hook_method(m_AD_CheckAndPlayVideo, (void *)ad_replacement_2, "CheckAndPlayVideo");
        if (s) { g_ad_mp_slot = s; g_adHooked++; }
    }
    if (m_Ad_Show0) {
        if (dk_hook_method(m_Ad_Show0, (void *)ad_replacement_show0, "LocalAd.Show")) g_adHooked++;
    }
    L("⑤ noAd: hooked=%d (play=%p show0=%p)", g_adHooked, m_AD_CheckAndPlayVideo, m_Ad_Show0);
}

static void ad_hook_remove(void) {
    if (!g_adHooked) return;
    dk_unhook_all();
    g_adHooked = 0;
    g_ad_mp_slot = NULL;
    L("⑤ noAd: 已移除");
}

// ───────────────────── 功能 ① 怪物自杀 / 秒杀 ─────────────────────
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
        int isPlayer = 0;
        for (int p = 0; p < pc; p++) if (e == players[p]) { isPlayer = 1; break; }
        if (isPlayer) { sk++; continue; }
        if (!is_inst_of(e, k_Char)) continue;
        if (k_Hero && is_inst_of(e, k_Hero)) { sk++; continue; }
        if (m_Char_getIsDead) {
            Il2CppObject *dead = ic_call(m_Char_getIsDead, e, NULL);
            if (dead && *(uint8_t *)((uint8_t *)dead + 0x10)) continue;
        }
        sc++;
        BOOL ok = NO;
        // 路线1: EnemyCommitSuicide(entity, reason)
        if (m_EM_EnemyCommitSuicide) {
            int32_t reason = 0;
            void *args[2] = { e, &reason };
            ic_call(m_EM_EnemyCommitSuicide, em, args);
            ok = YES;
        }
        // 路线2: SetHp(0) + OnDeath(tdd)
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
                    *(uint8_t  *)(t + 0x18) = 1;
                    *(int32_t  *)(t + 0x1C) = 6;
                    *(uint64_t *)(t + 0x28) = 999999999ULL;
                    void *args[1] = { tdd };
                    ic_call(m_Char_OnDeath, e, args);
                }
            }
        }
        dl++;
    }
    static int kl = 0;
    if (++kl <= 3 || kl % 40 == 0) L("① kill: 扫描%d 清%d 跳%d (玩家%d)", sc, dl, sk, pc);
}

// ───────────────────── 功能 ② 无敌 ─────────────────────
static void do_invincible(void) {
    void *ctx = get_ctx();
    if (!ctx) return;
    void *em = ctx_entity(ctx);
    if (!em) return;
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
    if (hn == 0 && m_EM_GetEntityValues && k_Hero) {
        void *list = ic_call(m_EM_GetEntityValues, em, NULL);
        if (list) {
            int32_t n = list_size(list); if (n > 800) n = 800;
            for (int i = 0; i < n && hn < 4; i++) {
                void *e = list_at(list, i);
                if (e && is_inst_of(e, k_Hero)) heroes[hn++] = e;
            }
        }
    }
    for (int i = 0; i < hn; i++) {
        void *h = heroes[i];
        if (!h) continue;
        if (m_Char_AddAbsInv) ic_call(m_Char_AddAbsInv, h, NULL);
        void *setHp = m_Char_setCurrentHp;
        if (!setHp) setHp = vmi(h, "set_CurrentHp", 1);
        if (setHp) {
            int64_t big = 999999999LL;
            void *args[1] = { &big };
            ic_call(setHp, h, args);
        }
        if (m_Char_AddStatus) {
            int32_t st = 2;   // 【推测】CharacterStatusType.ImmuneDamage (枚举序 None,ImmuneSelect,ImmuneDamage,...)
            void *args[1] = { &st };
            ic_call(m_Char_AddStatus, h, args);
        }
    }
    static int il = 0;
    if (++il <= 3 || il % 60 == 0)
        L("② inv: 英雄%d abs=%p setHp=%p status=%p", hn, m_Char_AddAbsInv, m_Char_setCurrentHp, m_Char_AddStatus);
}

// ───────────────────── 功能 ③ 一键通关 ─────────────────────
static void do_pass_chapter(void) {
    void *ctx = get_ctx();
    if (!ctx) { if (g_statusSub) g_statusSub.text = @"未在战斗中"; return; }
    do_kill();
    void *bm = ctx_battlemgr(ctx);
    if (!bm) { if (g_statusSub) g_statusSub.text = @"BattleManager 未就绪"; return; }
    if (m_BM_OnMissionClear) ic_call(m_BM_OnMissionClear, bm, NULL);
    if (m_BM_OnChapterEnd)   ic_call(m_BM_OnChapterEnd, bm, NULL);
    L("③ pass: OnMissionClear=%p OnChapterEnd=%p", m_BM_OnMissionClear, m_BM_OnChapterEnd);
    if (g_statusSub) g_statusSub.text = @"一键通关已触发 (清场+过关判定)";
}

// ───────────────────── 功能 ④ 游戏加速 ─────────────────────
static void *get_gamemanager(void) {
    static void *cache = NULL;
    if (cache) return cache;
    if (!k_GameMgr) return NULL;
    void *mi = mof(k_GameMgr, "get_Instance", 0);
    if (mi) {
        Il2CppObject *o = ic_call(mi, NULL, NULL);
        if (o) { cache = o; L("GameManager.Instance = %p", o); return o; }
    }
    return NULL;
}

static void do_speed(void) {
    float f = g_speedMult;
    int done = 0;
    if (m_GM_SetTimeScale) {
        void *gm = get_gamemanager();
        if (gm) { void *a[1] = { &f }; ic_call(m_GM_SetTimeScale, gm, a); done++; }
    }
    if (m_Game_SetTimeScale) { void *a[1] = { &f }; ic_call(m_Game_SetTimeScale, NULL, a); done++; }
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
        L("④ speed: %.2fx done=%d GM=%p Game=%p readback=%.2f",
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

// ───────────────────── 功能 ⑥ 局内经验 ─────────────────────
static void do_add_exp(void) {
    void *ctx = get_ctx();
    if (!ctx) { if (g_statusSub) g_statusSub.text = @"未在战斗中"; return; }
    void *bd = ctx_battledata(ctx);
    int done = 0;
    if (bd && m_BD_AddUserExp) {
        int32_t v = g_expValue;
        void *a[1] = { &v };
        ic_call(m_BD_AddUserExp, bd, a);
        done++;
    }
    void *bm = ctx_battlemgr(ctx);
    if (bm && m_BM_AddExpAndGold) { ic_call(m_BM_AddExpAndGold, bm, NULL); done++; }
    L("⑥ exp: AddUserExp(%d)=%d AddExpAndGold=%d done=%d", g_expValue,
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
    void *a[1] = { &v };
    if (m_BD_AddDropGold) ic_call(m_BD_AddDropGold, bd, a);
    if (m_BD_AddWaveGold) ic_call(m_BD_AddWaveGold, bd, a);
    L("⑦ gold: AddDropGold(%d)=%p AddWaveGold=%p", g_goldValue, m_BD_AddDropGold, m_BD_AddWaveGold);
    if (g_statusSub) g_statusSub.text = [NSString stringWithFormat:@"已加金币 +%d", g_goldValue];
}

// ───────────────────── 功能 ⑤ 免广告 (开关入口) ─────────────────────
static void do_no_ad(void) {
    if (g_noAdOn) ad_hook_install(); else ad_hook_remove();
    L("⑤ noAd: 开关=%d play=%p hooked=%d", g_noAdOn, m_AD_CheckAndPlayVideo, g_adHooked);
}

// ───────────────────── 主循环 tick (主线程) ─────────────────────
// ⚠️ 所有 il2cpp 调用只在这里 (主线程) 执行。每个 tick 内部按 tickCounter 降频,
//    避免高频反射调用影响游戏主线程帧率。
static int g_tickN = 0;

static void combat_tick(void) {
    if (!ic_ready) return;
    g_tickN++;
    if (!g_parsed) { resolve_step(); return; }

    int g = DK_GUARD_BEGIN();
    if (g == 0) {
        // 战斗状态只在每 3 tick (1.2s) 判一次, 降低反射频率
        if (g_tickN % 3 == 0) {
            BOOL alive = battle_alive();
            static BOOL wasIn = NO;
            if (alive != wasIn) {
                wasIn = alive; g_inBattle = alive;
                L(">> %s战斗 (world=%p ctx=%p)", alive ? "进入" : "离开", get_world(), get_ctx());
                if (alive) {
                    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
                    [ud setInteger:0 forKey:@"dk3_crashStreak"];
                    [ud synchronize];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (g_statusSub) g_statusSub.text = alive ? @"战斗中 ✓ 功能即时生效" : @"已就绪，进入关卡后生效";
                });
            }
        }
        // 免广告 hook 状态同步 (只在开关变化时)
        static BOOL adInstalled = NO;
        if (g_noAdOn != adInstalled) { do_no_ad(); adInstalled = g_noAdOn; }

        if (g_inBattle) {
            if (g_killOn  && (g_tickN % 2 == 0)) do_kill();       // 0.8s 一次
            if (g_invOn   && (g_tickN % 3 == 0)) do_invincible();
            if (g_speedOn && (g_tickN % 3 == 0)) do_speed();
            else if (g_speedWasOn && (g_tickN % 3 == 0)) restore_speed();
        }
        g_speedWasOn = g_speedOn;
        DK_GUARD_END();
        return;
    }
    L("⚠️ tick 捕获内存异常 (已跳过本次)");
    DK_GUARD_END();
}

// ───────────────────── UI ─────────────────────
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
- (void)expGo; - (void)goldGo;
- (void)expDec; - (void)expInc;
- (void)goldDec; - (void)goldInc;
- (void)spdDec; - (void)spdInc;
@end

static CGPoint dk_clamp(CGPoint c, CGSize sz, CGRect b) {
    CGFloat hw = sz.width / 2, hh = sz.height / 2;
    c.x = MAX(hw + 4, MIN(b.size.width - hw - 4, c.x));
    c.y = MAX(hh + 34, MIN(b.size.height - hh - 20, c.y));
    return c;
}

@implementation DK3Helper
- (void)ballTapped { g_panel.hidden = !g_panel.hidden; }
- (void)ballPan:(UIPanGestureRecognizer *)gr {
    CGPoint t = [gr translationInView:gr.view.superview];
    if (gr.state == UIGestureRecognizerStateBegan || gr.state == UIGestureRecognizerStateChanged) {
        CGPoint c = gr.view.center; c.x += t.x; c.y += t.y;
        gr.view.center = dk_clamp(c, gr.view.bounds.size, gr.view.superview.bounds);
        [gr setTranslation:CGPointZero inView:gr.view.superview];
    }
}
- (void)panelPan:(UIPanGestureRecognizer *)gr {
    CGPoint t = [gr translationInView:g_panel.superview];
    if (gr.state == UIGestureRecognizerStateBegan || gr.state == UIGestureRecognizerStateChanged) {
        CGPoint c = g_panel.center; c.x += t.x; c.y += t.y;
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
- (void)killSw:(UISwitch *)sw  { g_killOn  = sw.on; [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:@"dk3_kill"];  L("①秒杀→%d", sw.on); }
- (void)invSw:(UISwitch *)sw   { g_invOn   = sw.on; [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:@"dk3_inv"];   L("②无敌→%d", sw.on); }
- (void)speedSw:(UISwitch *)sw { g_speedOn = sw.on; [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:@"dk3_spd"];
                                 if (!sw.on) restore_speed(); L("④加速→%d (%.1fx)", sw.on, g_speedMult); }
- (void)noAdSw:(UISwitch *)sw  { g_noAdOn  = sw.on; [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:@"dk3_noad"];
                                 do_no_ad(); L("⑤免广告→%d", sw.on); }
- (void)passTap { do_pass_chapter(); }
- (void)expGo   { do_add_exp(); }
- (void)goldGo  { do_add_gold(); }
- (void)expDec  { if (g_expValue > 100) g_expValue -= 100;    g_expVal.text  = [NSString stringWithFormat:@"%d", g_expValue]; }
- (void)expInc  { if (g_expValue < 100000) g_expValue += 100; g_expVal.text  = [NSString stringWithFormat:@"%d", g_expValue]; }
- (void)goldDec { if (g_goldValue > 100) g_goldValue -= 100;  g_goldVal.text = [NSString stringWithFormat:@"%d", g_goldValue]; }
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
static UIView *mkStepCard(CGRect f, NSString *emoji, UIColor *bg, NSString *title, NSString *sub,
                          UILabel * __strong *outVal, id tgt, SEL dec, SEL inc, UIView *p) {
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
    CGFloat W = MIN(302, win.bounds.size.width - 24);
    CGFloat x0 = (win.bounds.size.width - W) / 2;
    CGFloat y = 76;
    CGFloat pad = 12, cw = (W - pad * 3) / 2, ch = 56;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(x0, 76, W, 500)];
    panel.backgroundColor = [UIColor colorWithRed:0.949 green:0.949 blue:0.973 alpha:1];
    panel.layer.cornerRadius = 20;
    panel.layer.shadowColor = UIColor.blackColor.CGColor;
    panel.layer.shadowOpacity = 0.25; panel.layer.shadowOffset = CGSizeMake(0, 6); panel.layer.shadowRadius = 14;
    panel.hidden = YES;
    [win addSubview:panel];
    g_panel = panel;

    mkLabel(@"弹壳战机 · 全功能", 15, UIFontWeightBold, DK_TEXT, CGRectMake(pad, 12, W - 80, 20), panel);
    g_statusSub = mkLabel(@"初始化中…", 9, UIFontWeightRegular, DK_SUB, CGRectMake(pad, 30, W - 80, 14), panel);
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(W - 40, 14, 26, 26);
    closeBtn.backgroundColor = DK_RED; closeBtn.layer.cornerRadius = 13;
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor colorWithRed:0.85 green:0.25 blue:0.25 alpha:1] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [closeBtn addTarget:g_helper action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:closeBtn];

    y = 52;
    mkToggleCard(CGRectMake(pad, y, cw, ch), @"🎯", DK_RED,   @"怪物自杀", @"全场怪物即死", g_killOn, g_helper, @selector(killSw:), panel);
    mkToggleCard(CGRectMake(pad*2+cw, y, cw, ch), @"🛡️", DK_BLUE, @"无敌", @"绝对无敌+满血", g_invOn, g_helper, @selector(invSw:), panel);
    y += ch + 8;
    mkToggleCard(CGRectMake(pad, y, cw, ch), @"⏱️", DK_GREEN, @"游戏加速", @"战斗整体变速", g_speedOn, g_helper, @selector(speedSw:), panel);
    mkToggleCard(CGRectMake(pad*2+cw, y, cw, ch), @"🚫", DK_GOLD, @"免广告", @"跳过视频直发奖", g_noAdOn, g_helper, @selector(noAdSw:), panel);
    y += ch + 8;
    mkGoCard(CGRectMake(pad, y, W - pad*2, 56), @"⚡", DK_GOLD, @"一键通关", g_helper, @selector(passTap), panel);
    y += 64;
    mkStepCard(CGRectMake(pad, y, W - pad*2, 56), @"🧭", DK_BLUE, @"加速倍率", @"点 ± 调整",
               &g_spdVal, g_helper, @selector(spdDec), @selector(spdInc), panel);
    g_spdVal.text = [NSString stringWithFormat:@"%.1fx", g_speedMult];
    y += 64;
    mkStepCard(CGRectMake(pad, y, W - pad*2, 56), @"⚡", DK_GREEN, @"单次经验", @"点 ± 改量",
               &g_expVal, g_helper, @selector(expDec), @selector(expInc), panel);
    g_expVal.text = [NSString stringWithFormat:@"%d", g_expValue];
    y += 58;
    mkGoCard(CGRectMake(pad, y, W - pad*2, 48), @"＋", DK_GREEN, @"增加局内经验", g_helper, @selector(expGo), panel);
    y += 56;
    mkStepCard(CGRectMake(pad, y, W - pad*2, 56), @"🪙", DK_GOLD, @"单次金币", @"点 ± 改量",
               &g_goldVal, g_helper, @selector(goldDec), @selector(goldInc), panel);
    g_goldVal.text = [NSString stringWithFormat:@"%d", g_goldValue];
    y += 58;
    mkGoCard(CGRectMake(pad, y, W - pad*2, 48), @"＋", DK_GOLD, @"增加局内金币", g_helper, @selector(goldGo), panel);
    y += 52;
    mkLabel(@"弹壳战机 1.1.7 · 单机PvE · 昆哥儿", 9, UIFontWeightRegular,
            [UIColor colorWithRed:0.69 green:0.69 blue:0.73 alpha:1],
            CGRectMake(pad, y, W - pad*2, 14), panel).textAlignment = NSTextAlignmentCenter;

    CGFloat ph = y + 26;
    panel.frame = CGRectMake(x0, 76, W, ph);
    g_panelPan = [[UIPanGestureRecognizer alloc] initWithTarget:g_helper action:@selector(panelPan:)];
    g_panelPan.delegate = g_helper;
    [panel addGestureRecognizer:g_panelPan];

    CGFloat bs = 58;
    UIButton *ball = [UIButton buttonWithType:UIButtonTypeCustom];
    ball.frame = CGRectMake(win.bounds.size.width - bs - 16, 150, bs, bs);
    ball.layer.cornerRadius = bs / 2;
    ball.backgroundColor = DK_TEAL;
    ball.layer.borderWidth = 2;
    ball.layer.borderColor = UIColor.whiteColor.CGColor;
    ball.layer.shadowColor = UIColor.blackColor.CGColor;
    ball.layer.shadowOpacity = 0.3; ball.layer.shadowOffset = CGSizeMake(0, 3); ball.layer.shadowRadius = 6;
    [ball setTitle:@"弹" forState:UIControlStateNormal];
    [ball setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    ball.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [ball addTarget:g_helper action:@selector(ballTapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *bp = [[UIPanGestureRecognizer alloc] initWithTarget:g_helper action:@selector(ballPan:)];
    bp.delegate = g_helper;
    [ball addGestureRecognizer:bp];
    [win addSubview:ball];
    g_ball = ball;
    L("UI ✓ 面板%.0fx%.0f + 球58 已挂载 (win %.0fx%.0f)", W, ph, win.bounds.size.width, win.bounds.size.height);
}

static void dk_ensure_overlay(void) {
    UIWindow *win = dk_game_window();
    if (!win) return;
    if (!g_ball) { dk_build_ui(); return; }
    if (g_ball.superview != win) [win addSubview:g_ball];
    if (g_panel.superview != win) [win addSubview:g_panel];
    if (!g_panel.hidden) [win bringSubviewToFront:g_panel];
    [win bringSubviewToFront:g_ball];
}

// ───────────────────── 安装 / 入口 ─────────────────────
// ⚠️ v3.0 真机教训: ctor 里不要做任何 il2cpp 调用 (SDK 未初始化)。
//    且 ctor 只允许执行一次 —— 日志里 ctor 出现 3 次 = 崩溃-重启循环的标志。
//    v3.1 加入崩溃熔断: 连续 3 次启动未进入战斗 → 自我禁用 (写 off 文件)。
static int dk_crash_streak(void) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    return (int)[ud integerForKey:@"dk3_crashStreak"];
}
static void dk_crash_streak_set(int v) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setInteger:v forKey:@"dk3_crashStreak"];
    [ud synchronize];
}

static BOOL g_installed = NO;   // 防重入 (同一进程多次触发)

static void dk_install_all(void) {
    if (g_installed) return;
    g_installed = YES;

    NSString *doc = dk_doc_path();
    if (doc && [NSFileManager.defaultManager fileExistsAtPath:
                [doc stringByAppendingPathComponent:@"dkzj3_off"]]) {
        L("dkzj3_off 存在 → 禁用 (删除该文件后重启游戏即可恢复)"); return;
    }
    // 崩溃熔断检查
    int streak = dk_crash_streak();
    if (streak >= 3) {
        L("⚠️ 连续 %d 次启动未进战斗 → 熔断自我禁用", streak);
        if (doc) {
            NSString *off = [doc stringByAppendingPathComponent:@"dkzj3_off"];
            [@"auto-disabled after 3 crash-restarts" writeToFile:off atomically:YES
                                                      encoding:NSUTF8StringEncoding error:nil];
        }
        return;
    }
    dk_crash_streak_set(streak + 1);
    L("== DKZJ v3.1 启动 (启动计数 %d/3) — unity base=%p slide=%d",
      streak + 1, (void *)g_unityBase, g_slide);

    dk_guard_install();
    if (!ic_init()) { L("X il2cpp 初始化失败 → 禁用"); return; }

    // 全部反射解析在主线程分步进行 (resolve_step 由 tick 驱动)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        dk_build_ui();
        if (g_statusSub) g_statusSub.text = @"解析中… (主线程分步)";
        [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(__unused NSTimer *t){
            combat_tick();
            static int k = 0;
            if (++k % 12 == 0) dk_ensure_overlay();
        }];
        L("install done — 点球开面板 (7 功能)");
    });
}

__attribute__((constructor))
static void dkzj_ctor(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid) { L("ctor: bundleIdentifier 为 nil → 等待"); }
    else if (![bid hasPrefix:@"com.survivor.ace"]) {
        L("ctor: bundle=%s ≠ com.survivor.ace* → skip", bid.UTF8String);
        return;
    }
    L("ctor: bundle=%s → 等 UnityFramework", bid ? bid.UTF8String : "(nil)");
    __block int tries = 0;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_global_queue(0, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 400 * NSEC_PER_MSEC, 0);
    dispatch_source_set_event_handler(timer, ^{
        tries++;
        if (find_unity_base()) {
            dispatch_source_cancel(timer);
            dispatch_async(dispatch_get_main_queue(), ^{ dk_install_all(); });
        } else if (tries > 150) {
            dispatch_source_cancel(timer);
            L("ctor: UnityFramework 超时未加载");
        }
    });
    dispatch_resume(timer);
}
