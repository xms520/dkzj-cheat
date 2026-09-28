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
// ★ BattleWorldContext 上的正确功能入口 (v3.3: 之前用 BattleData/BattleManager 层级太低, 无 UI 事件刷新)
static void *m_CTX_AddUserExp;          // ctx.AddUserExp(exp)
static void *m_CTX_AddDropGold;         // ctx.AddDropGold(gold)
static void *m_CTX_AddWaveGold;         // ctx.AddWaveGold(gold, hasEffect)
static void *m_CTX_AddNewWaveGold;      // ctx.AddNewWaveGold(gold)
static void *m_CTX_DisPathGoldUpdate;   // ctx.DisPathGoldUpdateEvent(hasEffect)
static void *m_CTX_ShowExpUI;           // ctx.ShowExpUI()
static void *m_CTX_TriggerLevelUp;      // ctx.TriggerLevelUpEvent(player)
static void *m_CTX_GetUserExp;          // ctx.get_UserExp()
static void *m_CTX_SetWinPlayerId;      // ctx.SetWinPlayerId(playerId)
static void *m_CTX_IncreaseMission;     // ctx.IncreaseMission(addExp)
static void *m_CTX_GetCurMissionId;     // ctx.get_CurMissionId()
static void *m_CTX_getCurWave;          // ctx.get_CurWave()
static void *m_CTX_getMissionCount;     // ctx.get_MissionCount()
static void *m_CTX_getCurMissionIndex;  // ctx.get_CurMissionIndex()
static void *m_CTX_getIsChapterComplete;// ctx.get_IsChapterComplete()
static void *m_CTX_GMSetCurMissionId;   // ctx.GMSetCurMissionId(missionId)
static void *m_CTX_AddExpAndGold;       // ctx.AddExpAndGold()
static void *m_CTX_OnWaveEnd;           // ctx.OnWaveEnd()
static int32_t g_myPlayerId = -1;       // WorldBattle.MyPlayerId (字段直读)
static BOOL    g_invCleaned = NO;       // 已清理历史误加状态位 (ImmuneSelect/PhysicalDetection)
static void *m_Ad_Show0;
static Il2CppClass *k_Ad_Fallback = NULL, *k_Ad_Player = NULL;
static void *m_Ad_Fb_IsReady, *m_Ad_Fb_Show4, *m_Ad_Fb_Show0;
static void *m_Ad_Pl_Close, *m_Ad_Pl_Skip;
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
enum { RS_WAIT_DOMAIN=0, RS_HF, RS_HFB, RS_AD, RS_COR,
       RS_C1, RS_C1b, RS_C2, RS_C2b, RS_C3, RS_C3b, RS_C3c,
       RS_M1, RS_M1b, RS_M1c, RS_M1d, RS_M2, RS_M2b, RS_M2c, RS_M3, RS_M3b, RS_M4, RS_M4b,
       RS_OFF, RS_DONE, RS_FAIL };
static int g_rs = RS_WAIT_DOMAIN;
static int g_rsTick = 0;
static int g_rsFails = 0;

static void rs_log(const char *stage, BOOL ok) {
    L("A[%s] %s", stage, ok ? "✓" : "✗");
}

// 每 tick 推进多步 (分步执行, 每次只做少量反射调用; 单步崩溃只影响该步)
static void resolve_step(void) {
    if (g_parsed || g_rs == RS_DONE || g_rs == RS_FAIL) return;
    if (++g_rsTick < 2) return;      // 每 2 个 tick (0.8s) 走一步
    g_rsTick = 0;

    for (int iter = 0; iter < 4; iter++) {   // 每轮最多推进 4 步 (加速完成)
        if (g_parsed || g_rs == RS_DONE || g_rs == RS_FAIL) return;
        switch (g_rs) {
        case RS_WAIT_DOMAIN:
            if (ic_domain_ready()) { g_rs = RS_HF; L("A[domain] ✓ il2cpp 域就绪"); }
            else if (++g_rsFails > 400) { g_rs = RS_FAIL; L("A[domain] ✗ 超时"); }
            return;                       // domain 未就绪时本 tick 结束
        case RS_HF:
            g_imgHF = ic_find_image("HotFix.dll");
            if (g_imgHF) { rs_log("HotFix.dll", YES); g_rs = RS_HFB; g_rsFails = 0; }
            else if (++g_rsFails % 10 == 0) L("A[HotFix.dll] 等待热更加载 (#%d)", g_rsFails);
            return;
        case RS_HFB:
            g_imgHFB = ic_find_image("HotFixBattle.dll");
            if (g_imgHFB) { rs_log("HotFixBattle.dll", YES); g_rs = RS_AD; g_rsFails = 0; }
            else if (++g_rsFails % 10 == 0) L("A[HotFixBattle.dll] 等待 (#%d)", g_rsFails);
            return;
        case RS_AD:
            g_imgAD = ic_find_image("GorillaAd.Runtime.dll");
            L("A[GorillaAd] %s", g_imgAD ? "✓" : "✗ (可缺)");
            g_rs = RS_COR; break;
        case RS_COR:
            g_imgCOR = ic_find_image("mscorlib.dll");
            L("A[mscorlib] %s", g_imgCOR ? "✓" : "✗ (可缺)");
            g_rs = RS_C1; break;
        case RS_C1:
            k_BattleGame  = cn(g_imgHF, "HotFix", "BattleGame");
            k_WorldBattle = cn(g_imgHF, "HotFix", "WorldBattle");
            L("A[C1] BG=%p WB=%p", k_BattleGame, k_WorldBattle);
            g_rs = RS_C1b; break;
        case RS_C1b:
            k_BLW = cn(g_imgHFB, "HotFix.BattleLogic", "BattleLogicWorld");
            k_Ctx = cn(g_imgHFB, "HotFix.BattleLogic", "BattleWorldContext");
            L("A[C1b] BLW=%p CTX=%p", k_BLW, k_Ctx);
            if (k_BattleGame && k_WorldBattle && k_Ctx) g_rs = RS_C2;
            else if (++g_rsFails > 40) { g_rs = RS_FAIL; L("A[C1b] ✗ 类缺失"); }
            break;
        case RS_C2:
            k_EM   = cn(g_imgHFB, "HotFix.BattleLogic", "EntityManager");
            k_Char = cn(g_imgHFB, "HotFix.BattleLogic", "EntityCharacter");
            L("A[C2] EM=%p Char=%p", k_EM, k_Char);
            if (k_Char) g_rs = RS_C2b; else if (++g_rsFails > 40) g_rs = RS_FAIL;
            break;
        case RS_C2b:
            k_Hero = cn(g_imgHFB, "HotFix.BattleLogic", "EntityHero");
            k_TDD  = cn(g_imgHFB, "HotFix.BattleLogic", "TakeDamageData");
            L("A[C2b] Hero=%p TDD=%p", k_Hero, k_TDD);
            g_rs = RS_C3; break;
        case RS_C3:
            k_BattleMgr  = cn(g_imgHFB, "HotFix.BattleLogic", "BattleManager");
            k_BattleData = cn(g_imgHFB, "HotFix.BattleLogic", "BattleData");
            L("A[C3] BM=%p BD=%p", k_BattleMgr, k_BattleData);
            g_rs = RS_C3b; break;
        case RS_C3b:
            k_ADMgr   = cn(g_imgHF, "HotFix", "ADModuleMgr");
            k_AdData  = cn(g_imgHF, "HotFix", "AdData");
            L("A[C3b] ADMgr=%p AdData=%p", k_ADMgr, k_AdData);
            g_rs = RS_C3c; break;
        case RS_C3c:
            k_Game    = cn(g_imgHF, "HotFix", "Game");
            k_GameMgr = cn(g_imgHF, "HotFix", "GameManager");
            k_I64     = cn(g_imgCOR, "System", "Int64");
            L("A[C3c] Game=%p GM=%p I64=%p", k_Game, k_GameMgr, k_I64);
            g_rs = RS_M1; break;
        case RS_M1:
            m_BG_getWorld      = mof(k_BattleGame, "get_World", 0);
            m_WB_getLogicWorld = mof(k_WorldBattle, "get_LogicWorld", 0);
            L("A[M1] getWorld=%p logicWorld=%p", m_BG_getWorld, m_WB_getLogicWorld);
            g_rs = RS_M1b; break;
        case RS_M1b:
            m_Ctx_getEntity    = mof(k_Ctx, "get_Entity", 0);
            m_Ctx_getBattleMgr = mof(k_Ctx, "get_BattleMgr", 0);
            m_Ctx_getBattleData= mof(k_Ctx, "get_BattleData", 0);
            L("A[M1b] ctxEntity=%p ctxBM=%p ctxBD=%p", m_Ctx_getEntity, m_Ctx_getBattleMgr, m_Ctx_getBattleData);
            g_rs = RS_M1c; break;
        case RS_M1c:
            if (k_Ctx) {
                m_CTX_AddUserExp          = mof(k_Ctx, "AddUserExp", 1);
                m_CTX_AddDropGold         = mof(k_Ctx, "AddDropGold", 1);
                m_CTX_AddWaveGold         = mof(k_Ctx, "AddWaveGold", 2);
                m_CTX_AddNewWaveGold      = mof(k_Ctx, "AddNewWaveGold", 1);
                m_CTX_DisPathGoldUpdate   = mof(k_Ctx, "DisPathGoldUpdateEvent", 1);
                m_CTX_ShowExpUI           = mof(k_Ctx, "ShowExpUI", 0);
                m_CTX_TriggerLevelUp      = mof(k_Ctx, "TriggerLevelUpEvent", 1);
                m_CTX_GetUserExp          = mof(k_Ctx, "get_UserExp", 0);
            }
            L("A[M1c] ctxExp=%p ctxGold=%p ctxWaveGold=%p goldEvent=%p",
              m_CTX_AddUserExp, m_CTX_AddDropGold, m_CTX_AddWaveGold, m_CTX_DisPathGoldUpdate);
            g_rs = RS_M1d; break;
        case RS_M1d:
            if (k_Ctx) {
                m_CTX_SetWinPlayerId      = mof(k_Ctx, "SetWinPlayerId", 1);
                m_CTX_IncreaseMission     = mof(k_Ctx, "IncreaseMission", 1);
                m_CTX_GetCurMissionId     = mof(k_Ctx, "get_CurMissionId", 0);
                m_CTX_getCurWave          = mof(k_Ctx, "get_CurWave", 0);
                m_CTX_getMissionCount     = mof(k_Ctx, "get_MissionCount", 0);
                m_CTX_getCurMissionIndex  = mof(k_Ctx, "get_CurMissionIndex", 0);
                m_CTX_getIsChapterComplete= mof(k_Ctx, "get_IsChapterComplete", 0);
                m_CTX_GMSetCurMissionId   = mof(k_Ctx, "GMSetCurMissionId", 1);
                m_CTX_AddExpAndGold       = mof(k_Ctx, "AddExpAndGold", 0);
                m_CTX_OnWaveEnd           = mof(k_Ctx, "OnWaveEnd", 0);
            }
            L("A[M1d] win=%p incMission=%p curMission=%p wave=%p count=%p",
              m_CTX_SetWinPlayerId, m_CTX_IncreaseMission, m_CTX_GetCurMissionId,
              m_CTX_getCurWave, m_CTX_getMissionCount);
            g_rs = RS_M2; break;
        case RS_M2:
            if (k_EM) {
                m_EM_GetEntityValues    = mof(k_EM, "GetEntityValues", 0);
                m_EM_GetAllPlayer       = mof(k_EM, "GetAllPlayer", 0);
                m_EM_EnemyCommitSuicide = mof(k_EM, "EnemyCommitSuicide", 2);
            }
            L("A[M2] vals=%p allPlayer=%p suicide=%p", m_EM_GetEntityValues, m_EM_GetAllPlayer, m_EM_EnemyCommitSuicide);
            g_rs = RS_M2b; break;
        case RS_M2b:
            if (k_Char) {
                m_Char_SetHp     = mof(k_Char, "SetHp", 1);
                m_Char_OnDeath   = mof(k_Char, "OnDeath", 1);
                m_Char_getIsDead = mof(k_Char, "get_IsDead", 0);
                m_Char_Suicide   = mof(k_Char, "Suicide", 1);
            }
            L("A[M2b] SetHp=%p OnDeath=%p IsDead=%p", m_Char_SetHp, m_Char_OnDeath, m_Char_getIsDead);
            g_rs = RS_M2c; break;
        case RS_M2c:
            if (k_Char) {
                m_Char_AddAbsInv    = mof(k_Char, "AddAbsoluteInvincibility", 0);
                m_Char_RemoveAbsInv = mof(k_Char, "RemoveAbsoluteInvincibility", 0);   // ★ v3.7 补: 原先漏解析
                m_Char_AddStatus    = mof(k_Char, "AddCharacterStatus", 1);
                m_Char_RemoveStatus = mof(k_Char, "RemoveCharacterStatus", 1);          // ★ v3.7 补: 原先漏解析
                m_Char_getCurrentHp = mof(k_Char, "get_CurrentHp", 0);
                m_Char_setCurrentHp = mof(k_Char, "set_CurrentHp", 1);
            }
            L("A[M2c] absInv=%p/%p status=%p/%p curHp=%p/%p",
              m_Char_AddAbsInv, m_Char_RemoveAbsInv, m_Char_AddStatus, m_Char_RemoveStatus,
              m_Char_getCurrentHp, m_Char_setCurrentHp);
            g_rs = RS_M3; break;
        case RS_M3:
            if (k_BattleMgr) {
                m_BM_AddExpAndGold  = mof(k_BattleMgr, "AddExpAndGold", 0);
                m_BM_OnMissionClear = mof(k_BattleMgr, "OnMissionClear", 0);
                m_BM_OnChapterEnd   = mof(k_BattleMgr, "OnChapterEnd", 0);
            }
            L("A[M3] expAndGold=%p missionClear=%p chapterEnd=%p", m_BM_AddExpAndGold, m_BM_OnMissionClear, m_BM_OnChapterEnd);
            g_rs = RS_M3b; break;
        case RS_M3b:
            if (k_BattleData) {
                m_BD_AddUserExp  = mof(k_BattleData, "AddUserExp", 1);
                m_BD_AddDropGold = mof(k_BattleData, "AddDropGold", 1);
                m_BD_AddWaveGold = mof(k_BattleData, "AddWaveGold", 1);
            }
            L("A[M3b] AddUserExp=%p AddDropGold=%p AddWaveGold=%p", m_BD_AddUserExp, m_BD_AddDropGold, m_BD_AddWaveGold);
            g_rs = RS_M4; break;
        case RS_M4:
            if (k_ADMgr) m_AD_CheckAndPlayVideo = mof(k_ADMgr, "CheckAndPlayVideo", 2);
            if (k_GameMgr) m_GM_SetTimeScale = mof(k_GameMgr, "SetTimeScale", 1);
            L("A[M4] adPlay=%p GM.SetTimeScale=%p", m_AD_CheckAndPlayVideo, m_GM_SetTimeScale);
            g_rs = RS_M4b; break;
        case RS_M4b:
            if (k_Game) m_Game_SetTimeScale = mof(k_Game, "SetTimeScale", 1);
            // 免广告第二入口: FallbackRewardedVideo.IsReady()→true + Show(...) 直接发奖
            if (g_imgAD && !k_Ad_Fallback)
                k_Ad_Fallback = cn(g_imgAD, "GorillaAd.Runtime", "FallbackRewardedVideo");
            if (k_Ad_Fallback) {
                m_Ad_Fb_IsReady = mof(k_Ad_Fallback, "IsReady", 0);
                m_Ad_Fb_Show4   = mof(k_Ad_Fallback, "Show", 4);
                m_Ad_Fb_Show0   = mof(k_Ad_Fallback, "Show", 0);
            }
            // LocalRewardedVideoPlayer.OnCloseClicked/OnSkipClicked (本地视频"点击关闭")
            if (g_imgAD && !k_Ad_Player)
                k_Ad_Player = cn(g_imgAD, "GorillaAd.Runtime", "LocalRewardedVideoPlayer");
            if (k_Ad_Player) {
                m_Ad_Pl_Close = mof(k_Ad_Player, "OnCloseClicked", 0);
                m_Ad_Pl_Skip  = mof(k_Ad_Player, "OnSkipClicked", 0);
            }
            L("A[M4b] Game.SetTimeScale=%p fbIsReady=%p fbShow4=%p plClose=%p",
              m_Game_SetTimeScale, m_Ad_Fb_IsReady, m_Ad_Fb_Show4, m_Ad_Pl_Close);
            g_rs = RS_OFF; break;
        case RS_OFF:
            if (k_WorldBattle) off_CurLogicWorld  = foff(k_WorldBattle, "CurLogicWorld");
            if (k_BLW)         off_BLW_worldCtx   = foff(k_BLW, "_worldContext");
            if (k_Ctx)         off_Ctx_gameSpeed  = foff(k_Ctx, "gameSpeed");
            if (k_WorldBattle) off_World_timeScale= foff(k_WorldBattle, "_curTimeScale");
            if (k_ADMgr)       off_AD_onClose     = foff(k_ADMgr, "_onClose");
            L("A[OFF] curLogicWorld=0x%x worldCtx=0x%x gameSpeed=0x%x timeScale=0x%x adOnClose=0x%x",
              off_CurLogicWorld, off_BLW_worldCtx, off_Ctx_gameSpeed, off_World_timeScale, off_AD_onClose);
            if (!m_BG_getWorld && off_CurLogicWorld <= 0) {
                L("A ✗ 无可用世界入口 → 功能不可用"); g_rs = RS_FAIL; return;
            }
            g_parsed = YES; g_rs = RS_DONE;
            L("A ✓✓ 解析完成 — 进入关卡后功能生效");
            {
                NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
                [ud setInteger:0 forKey:@"dk3_crashStreak"];
                [ud synchronize];
            }
            if (g_statusSub) g_statusSub.text = @"已就绪，进入关卡后生效";
            return;
        default: return;
        }
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

// 运行时类名 (诊断用: 确认拿到的对象类型正确)
static const char *cls_name_of(void *obj) {
    if (!obj || !I.object_get_class || !I.class_get_name) return "?";
    const char *r = NULL;
    if (DK_GUARD_BEGIN() == 0) {
        Il2CppClass *k = (Il2CppClass *)I.object_get_class(obj);
        if (k) r = I.class_get_name(k);
    }
    DK_GUARD_END();
    return r ? r : "?";
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

// IsReady() → true (让游戏认为"本地兜底视频已就绪", 从而跳过 SDK 广告请求)
static int ad_ready_true(void *self) { return 1; }
// LocalRewardedVideoPlayer.OnCloseClicked/OnSkipClicked → 直接当作已看完
static void ad_player_close(void *self) {
    static int l = 0;
    if (l++ < 6) L("⑤ noAd: 拦截 LocalRewardedVideoPlayer 关闭(self=%p)", self);
    // 尝试触发 OnRewarded/OnClosed 委托
    const char *fns[] = { "OnRewarded", "OnClosed" };
    for (int i = 0; i < 2; i++) {
        int32_t off = foff((Il2CppClass *)I.object_get_class(self), fns[i]);
        if (off > 0) {
            void *d = *(void **)((uint8_t *)self + off);
            if (d && looks_like_delegate(d)) delegate_invoke(d);
        }
    }
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
    if (m_Ad_Fb_IsReady) {
        if (dk_hook_method(m_Ad_Fb_IsReady, (void *)ad_ready_true, "Fb.IsReady")) g_adHooked++;
    }
    if (m_Ad_Pl_Close) {
        if (dk_hook_method(m_Ad_Pl_Close, (void *)ad_player_close, "Player.OnClose")) g_adHooked++;
    }
    if (m_Ad_Pl_Skip) {
        if (dk_hook_method(m_Ad_Pl_Skip, (void *)ad_player_close, "Player.OnSkip")) g_adHooked++;
    }
    L("⑤ noAd: hooked=%d (play=%p show0=%p fbReady=%p plClose=%p)",
      g_adHooked, m_AD_CheckAndPlayVideo, m_Ad_Show0, m_Ad_Fb_IsReady, m_Ad_Pl_Close);
}

static void ad_hook_remove(void) {
    if (!g_adHooked) return;
    dk_unhook_all();      // 当前只有广告 hook 使用该表, 安全
    g_adHooked = 0;
    g_ad_mp_slot = NULL;
    L("⑤ noAd: 已移除 (hook 表已清空, 可重新安装)");
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
// ⚠️ v3.6 修复「本体在宝箱上识别不到」:
//   CharacterStatusType 是【位标志】, 真实值经两个独立枚举(HitCamp/Camp)交叉标定为:
//     None=0, ImmuneSelect=1, ImmuneDamage=2, ImmuneControl=4, ImmuneDeBuff=8, ImmunePhysicalDetection=16
//   v3.5 误加 17 = ImmuneSelect(1) | ImmunePhysicalDetection(16)
//     → 物理检测免疫 → 宝箱/掉落物/碰撞体全部识别不到 ✓ 与用户反馈完全吻合
//   现改为: 只维持血量 + AddAbsoluteInvincibility(引擎自带无敌语义, 不改物理层), 不再乱加 status。
//   并主动清理历史误加的 1 / 16 / 17 状态。
static void inv_cleanup_bad_status(void *hero) {
    if (!hero || !m_Char_RemoveStatus) return;
    const int32_t bad[] = { 1, 16, 17 };   // ImmuneSelect / ImmunePhysicalDetection / 组合
    for (int i = 0; i < 3; i++) {
        int32_t v = bad[i];
        void *a[1] = { &v };
        ic_call(m_Char_RemoveStatus, hero, a);
    }
}

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
        // ① 清理历史误加的物理检测免疫状态 (影响宝箱拾取)
        //    ⚠️ 只在首次执行; 若 RemoveCharacterStatus 指针缺失则跳过 (避免假日志)
        if (!g_invCleaned) {
            if (m_Char_RemoveStatus) inv_cleanup_bad_status(h);
            else if (h) L("② inv: ⚠️ RemoveCharacterStatus 未解析, 无法清理状态位 (本次不动状态)");
        }
        // ② 引擎自带绝对无敌 (不改物理层, 不干扰宝箱)
        if (m_Char_AddAbsInv) ic_call(m_Char_AddAbsInv, h, NULL);
        // ③ 血量维持
        void *setHp = m_Char_setCurrentHp;
        if (!setHp) setHp = vmi(h, "set_CurrentHp", 1);
        if (setHp) {
            int64_t big = 999999999LL;
            void *a[1] = { &big };
            ic_call(setHp, h, a);
        }
    }
    if (hn > 0) g_invCleaned = YES;
    static int il = 0;
    if (++il <= 3 || il % 60 == 0)
        L("② inv: 英雄%d absInv=%p setHp=%p 已清误加状态=%d (不干扰宝箱拾取)",
          hn, m_Char_AddAbsInv, m_Char_setCurrentHp, g_invCleaned);
}

// 关闭无敌: 解除绝对无敌 + 恢复血量 (恢复物理检测不受影响)
static void inv_off(void) {
    void *ctx = get_ctx();
    if (!ctx) return;
    void *em = ctx_entity(ctx);
    if (!em || !m_EM_GetAllPlayer) return;
    void *parr = ic_call(m_EM_GetAllPlayer, em, NULL);
    if (!parr) return;
    int32_t pn = arr_len(parr); if (pn > 4) pn = 4;
    for (int i = 0; i < pn; i++) {
        void *h = arr_at(parr, i);
        if (!h) continue;
        if (m_Char_RemoveAbsInv) ic_call(m_Char_RemoveAbsInv, h, NULL);
        inv_cleanup_bad_status(h);
    }
    g_invCleaned = NO;
    L("② inv: 已关闭 — 解除绝对无敌 + 清理状态位");
}

// ───────────────────── 功能 ③ 一键通关 ─────────────────────
// v3.3 修正: BattleManager.OnMissionClear() 是抽象基类实现, 清波/下一关流程不跑。
// 改为 BattleWorldContext 路线: 先清场 → IncreaseMission(1) 推进关卡 → SetWinPlayerId 判胜
//   IncreaseMission 内部会处理 mission 索引 + 波次; GMSetCurMissionId 可直接跳关。
static void do_pass_chapter(void) {
    void *ctx = get_ctx();
    if (!ctx) { if (g_statusSub) g_statusSub.text = @"未在战斗中"; return; }
    do_kill();                                     // ① 先清场, 否则波次逻辑会重新刷怪

    int32_t beforeMission = -1, beforeWave = -1, missionCount = 0;
    if (m_CTX_GetCurMissionId) {
        Il2CppObject *r = ic_call(m_CTX_GetCurMissionId, ctx, NULL);
        beforeMission = r ? *(int32_t *)((uint8_t *)r + 0x10) : -1;
    }
    if (m_CTX_getCurWave) {
        Il2CppObject *r = ic_call(m_CTX_getCurWave, ctx, NULL);
        beforeWave = r ? *(int32_t *)((uint8_t *)r + 0x10) : -1;
    }
    if (m_CTX_getMissionCount) {
        Il2CppObject *r = ic_call(m_CTX_getMissionCount, ctx, NULL);
        missionCount = r ? *(int32_t *)((uint8_t *)r + 0x10) : 0;
    }
    // 玩家 id: WorldBattle.MyPlayerId 字段直读 (off 未知时用 1)
    int32_t pid = g_myPlayerId;
    if (pid <= 0) {
        void *w = get_world();
        if (w) {
            static int32_t offPid = -2;
            if (offPid == -2) offPid = foff(k_WorldBattle, "MyPlayerId");
            if (offPid > 0) pid = *(int32_t *)((uint8_t *)w + offPid);
        }
        if (pid > 0) g_myPlayerId = pid;
    }
    int done = 0;
    // ① 结束当前波
    if (m_CTX_OnWaveEnd) { ic_call(m_CTX_OnWaveEnd, ctx, NULL); done++; }
    // ② 推进关卡 (addExp=1 表示附带经验结算)
    if (m_CTX_IncreaseMission) { int32_t ae = 1; void *a[1] = { &ae }; ic_call(m_CTX_IncreaseMission, ctx, a); done++; }
    // ③ 直接跳到最后一关 (若 missionCount 已知)
    if (m_CTX_GMSetCurMissionId && missionCount > 0) {
        int32_t last = missionCount - 1;
        void *a[1] = { &last };
        ic_call(m_CTX_GMSetCurMissionId, ctx, a); done++;
    }
    // ④ 标记胜利者 (结算判定用)
    if (m_CTX_SetWinPlayerId && pid > 0) { void *a[1] = { &pid }; ic_call(m_CTX_SetWinPlayerId, ctx, a); done++; }
    // ⑤ 兜底: BattleManager 路线
    void *bm = ctx_battlemgr(ctx);
    if (bm) {
        if (m_BM_OnMissionClear) { ic_call(m_BM_OnMissionClear, bm, NULL); done++; }
        if (m_BM_OnChapterEnd)   { ic_call(m_BM_OnChapterEnd, bm, NULL); done++; }
    }
    int32_t afterMission = -1, afterWave = -1;
    if (m_CTX_GetCurMissionId) {
        Il2CppObject *r = ic_call(m_CTX_GetCurMissionId, ctx, NULL);
        afterMission = r ? *(int32_t *)((uint8_t *)r + 0x10) : -1;
    }
    if (m_CTX_getCurWave) {
        Il2CppObject *r = ic_call(m_CTX_getCurWave, ctx, NULL);
        afterWave = r ? *(int32_t *)((uint8_t *)r + 0x10) : -1;
    }
    L("③ pass: mission %d→%d wave %d→%d (总关%d pid=%d) incMission=%p win=%p done=%d",
      beforeMission, afterMission, beforeWave, afterWave, missionCount, pid,
      m_CTX_IncreaseMission, m_CTX_SetWinPlayerId, done);
    if (g_statusSub) g_statusSub.text = [NSString stringWithFormat:@"通关: 关%d→%d", beforeMission, afterMission];
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
// v3.3 修正: 原 BattleData.AddUserExp 只写 PlayerExp 字段, 无 UI/升级事件 → 肉眼无感。
// 改为 BattleWorldContext.AddUserExp (会走 DispatchUpdateExpRenderEvent + 升级判定) + ShowExpUI。
static void do_add_exp(void) {
    void *ctx = get_ctx();
    if (!ctx) { if (g_statusSub) g_statusSub.text = @"未在战斗中"; return; }
    int done = 0;
    int32_t v = g_expValue;
    if (m_CTX_AddUserExp) {
        void *a[1] = { &v };
        ic_call(m_CTX_AddUserExp, ctx, a);
        done++;
    }
    if (m_CTX_ShowExpUI) { ic_call(m_CTX_ShowExpUI, ctx, NULL); done++; }
    // 辅助: 结算型 AddExpAndGold (ctx 版本)
    if (m_CTX_AddExpAndGold) { ic_call(m_CTX_AddExpAndGold, ctx, NULL); done++; }
    // 兜底: 旧的 BattleData 路线
    if (!m_CTX_AddUserExp) {
        void *bd = ctx_battledata(ctx);
        if (bd && m_BD_AddUserExp) { void *a[1] = { &v }; ic_call(m_BD_AddUserExp, bd, a); done++; }
    }
    static int el = 0;
    if (++el <= 3 || el % 20 == 0) {
        int32_t back = 0;
        if (m_CTX_GetUserExp) {
            Il2CppObject *r = ic_call(m_CTX_GetUserExp, ctx, NULL);
            back = r ? *(int32_t *)((uint8_t *)r + 0x10) : 0;
        }
        L("⑥ exp: ctx.AddUserExp(%d)=%p ShowExpUI=%p done=%d UserExp回读=%d",
          g_expValue, m_CTX_AddUserExp, m_CTX_ShowExpUI, done, back);
    }
    if (g_statusSub) g_statusSub.text = [NSString stringWithFormat:@"已加经验 +%d", g_expValue];
}

// ───────────────────── 功能 ⑦ 局内金币 ─────────────────────
// v3.3 修正: 原 BattleData.AddDropGold 只写 _dropGold 字段, 不刷 UI。
// 改为 BattleWorldContext.AddDropGold/AddWaveGold(2参, hasEffect=true) + DisPathGoldUpdateEvent(1)。
static void do_add_gold(void) {
    void *ctx = get_ctx();
    if (!ctx) { if (g_statusSub) g_statusSub.text = @"未在战斗中"; return; }
    int32_t v = g_goldValue;
    int done = 0;
    if (m_CTX_AddDropGold) { void *a[1] = { &v }; ic_call(m_CTX_AddDropGold, ctx, a); done++; }
    if (m_CTX_AddWaveGold) {
        int32_t hasEffect = 1;
        void *a[2] = { &v, &hasEffect };
        ic_call(m_CTX_AddWaveGold, ctx, a); done++;
    }
    if (m_CTX_DisPathGoldUpdate) { int32_t he = 1; void *a[1] = { &he }; ic_call(m_CTX_DisPathGoldUpdate, ctx, a); done++; }
    // 兜底
    if (!m_CTX_AddDropGold) {
        void *bd = ctx_battledata(ctx);
        if (bd && m_BD_AddDropGold) { void *a[1] = { &v }; ic_call(m_BD_AddDropGold, bd, a); done++; }
        if (bd && m_BD_AddWaveGold) { void *a[1] = { &v }; ic_call(m_BD_AddWaveGold, bd, a); done++; }
    }
    static int gl = 0;
    if (++gl <= 3 || gl % 20 == 0)
        L("⑦ gold: ctxAddDropGold=%p ctxAddWaveGold=%p goldEvent=%p done=%d",
          m_CTX_AddDropGold, m_CTX_AddWaveGold, m_CTX_DisPathGoldUpdate, done);
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
                void *w0 = get_world(), *c0 = get_ctx();
                L(">> %s战斗 (world=%p ctx=%p)", alive ? "进入" : "离开", w0, c0);
                if (alive) {
                    void *em0 = ctx_entity(c0), *bm0 = ctx_battlemgr(c0), *bd0 = ctx_battledata(c0);
                    L("   RTTI: world=%s ctx=%s EM=%s BM=%s BD=%s",
                      cls_name_of(w0), cls_name_of(c0), cls_name_of(em0), cls_name_of(bm0), cls_name_of(bd0));
                    static int32_t offPid2 = -2;
                    if (offPid2 == -2) offPid2 = foff(k_WorldBattle, "MyPlayerId");
                    if (offPid2 > 0) {
                        g_myPlayerId = *(int32_t *)((uint8_t *)w0 + offPid2);
                        L("   MyPlayerId(off 0x%x) = %d", offPid2, g_myPlayerId);
                    } else L("   MyPlayerId 字段未命中 (off=%d)", offPid2);
                }
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
        // 免广告 hook 状态同步 (开关变化时; 重复安装由 g_adHooked 幂等保护)
        static BOOL adInstalled = NO;
        if (g_noAdOn != adInstalled) { do_no_ad(); adInstalled = g_noAdOn; }

        if (g_inBattle) {
            if (g_killOn  && (g_tickN % 3 == 0)) do_kill();       // 1.2s 一次 (降频防卡顿)
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
// ── 黑色面板主题 ──
#define DK_PANEL  [UIColor colorWithRed:0.07 green:0.07 blue:0.09 alpha:0.97]   // 面板底
#define DK_CARD   [UIColor colorWithRed:0.13 green:0.13 blue:0.16 alpha:1]      // 卡片底
#define DK_CARD2  [UIColor colorWithRed:0.18 green:0.18 blue:0.22 alpha:1]      // 卡片底(亮)
#define DK_TEAL   [UIColor colorWithRed:0.24 green:0.78 blue:0.85 alpha:1]      // 主色(青)
#define DK_TEALBG [UIColor colorWithRed:0.16 green:0.28 blue:0.32 alpha:1]      // 主色浅底
#define DK_RED    [UIColor colorWithRed:0.30 green:0.14 blue:0.16 alpha:1]
#define DK_BLUE   [UIColor colorWithRed:0.14 green:0.19 blue:0.32 alpha:1]
#define DK_GREEN  [UIColor colorWithRed:0.13 green:0.26 blue:0.20 alpha:1]
#define DK_GOLD   [UIColor colorWithRed:0.30 green:0.24 blue:0.13 alpha:1]
#define DK_TEXT   [UIColor colorWithRed:0.96 green:0.96 blue:0.98 alpha:1]      // 主文字(白)
#define DK_SUB    [UIColor colorWithRed:0.60 green:0.62 blue:0.68 alpha:1]      // 副文字(灰)

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
- (void)invSw:(UISwitch *)sw   { g_invOn = sw.on; [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:@"dk3_inv"];
                                 if (!sw.on) inv_off();          // 关闭时恢复无敌/清状态位
                                 L("②无敌→%d", sw.on); }
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

// ───────────────────── 头像 (base64 JPEG 内嵌, 31 段) ─────────────────────
static UIImage *g_avatarImg = nil;
static int g_avatarTried = 0;
static UIImage *dk_avatar_image(void) {
    if (g_avatarImg) return g_avatarImg;
    if (g_avatarTried) return nil;
    g_avatarTried = 1;
    NSMutableString *m = [NSMutableString stringWithCapacity:18080];
    [m appendString:@"/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAUDBAQEAwUEBAQFBQUGBwwIBwcHBw8LCwkMEQ8SEhEPERETFhwXExQaFRERGCEYGh0dHx8fExciJCIeJBweHx7/2wBDAQUFBQcGBw4ICA4eFBEUHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh7/wAARCAEAAQADASIAAhEBAxEB/8QAHQAAAQQDAQEAAAAAAAAAAAAABgMEBQcBAggACf/EAEMQAAEDAwICBwQIBQIGAwEBAAECAwQABREGIRIxBxNBUWFxgRQikaEIFSMyQlKxwTNicoLRJOEWQ1OSovAlRMJzsv/EABsBAAIDAQEBAAAAAAAAAAAAAAMEAQIFAAYH/8QAMxEAAgIBBAECBAQFBAMAAAAAAQIAAxEEEiExBSJBEzJRYQaBkaFCUnGx0TNi4fAjJMH/2gAMAwEAAhEDEQA/AOs11EXu6phMrS2sdYBlSj+D/enN5nJhME8QCyMjP4R31VmpbyqStTTSj1YO5zuo95oF94QYEZ02nNhyeoz1Dc1zZBShRKc9+STUeGiw"];
    [m appendString:@"grzlfarsT4Dxpe3xytSpDh4W081H9qdR43t7vFjgjo5DvrLILHJ7myCqjA6kMiG7JUVYITnnWJjCIqcc1nkKI5LrEaOt4J+yQeFA/Or/ABTa2WpT6jcJwPEo5QmpKYOB3OD5GT1B5EFfD1z2eI/dFNZERaiSaMpEMrUVEUxlxkNoKlYArvhYkC7Jge5EIJ2NYTBUo4IO258KJREKw2UJy47/AA0+H5j4UxvJbiMmM0rKvxr7zVCkKrwdktcS+pZGTyzTe6tItkTjd/iHkKL9PWxCYDt1kjDSQVAnuHbVTdIOoA9Jee4jwJOG0jtqjV4H9ZdXyT9pBalvKkLKUnicVyT+9V7dr1xylNhSn3En3sAkDwFTSI8i6SVIJV7x+0UD/wCIotsmmo0doJSwlPkKNWFQRe1y54lYpntO/ZvApJ7xg0daV1tItGi3LWHCH2ZKlNOZ5JUkDI8dsUe2zRrd4Ps/sLb6DseNAIqyNA9BulLdLTPmW1Elzmlp5RW2jySdqlmDDEotnw+TOWjfb0ZJlNNzHE5yVJBA+dWjo7Wn1pb24N2UXGj7qXD95s9x/wAV0Xd+jDRk5koXY4zRI+80nhPy"];
    [m appendString:@"qrdWdCCITjk3Try0q/Eys5SsfsfGhNx0IRL1bgmBt6gFhwqQeJCt0qHIioRzIJqciPSIb7lkvDam1pPCgrG6T/io+6RVMPKSRQ8DsRnMjFnHbSSiRWz2UmklHO4NSJUxUOhQ4V8u/upJWWnNj5GtVEEYzg0kXCPs3Dt2Huq4lSMwh01qGfZbi1OgSVx5DSspUk/+5rqLoy15C1jbcKKGLmynL7A5K/nT4d47K47CiFYOxFTemb9Osl0YnwX1svsqCkqB/wDcjwpyi4rM/VacP13O2FE1jioe6PNWQtYafRPY4W5KMIksg/w1+H8p7P8AaiBYrSBBHExypBwZtxV7NaAVk12Z08o17GRWvbSmNsVw5nGV5rHUCpC1ttuZBO576GbcyudMS2ORO9RMyXxKKirmanhxWa1JaVtPlJyodrSDyHnWIX3nJnoxWK12iLy3EPyBCYOGW/vEfiNKOyusWm3xVcCQMur/ACioF6Z7IyENnLy9h35qStUcNxftl4SfeeX3+FWBx/WVK/pJaDFRNdEl8cMNn3WUfm8al/4pyQAkbAdwqKhSFSlggcLKdkJqXLqEN5JwBRUHEXtY5xG80tMt"];
    [m appendString:@"KWogJA7aDETkXi5u8PF7BFILpT/zFdiB4k/vUb0iapdflJstsy486oIwnmSdsUUaPtbFttzfWYLELKlq/wCs+fvHxA5Dy8aqzbjgQqJsXc0VuP8A8bCU8/w+2vjJA5Np7Eiq7uL7s+6x7awftZLyWx4ZO59BvU9rC7qecdcWqhzotH1trp+Uo5biNhCT3LXsT6JCqG2M7RCoCAWMJ+l66tWTTUSyxCEqeQCrHMIGw+Nc2XR9253MNtkkBXCjz7VelH3TPqNVzv0x1peUlfUsDuSNhQxoy2cZ9qIyFbI/pHb6864nJLSfkULJvTdmQwwkBPLto701p924yEoSkhAIyaQ09bFy5CGG08yMnuq6tJWJqEwjhbAI7cVQcwDvtm+mdOx4DKAlsAgd1FrDQQnAGMVhhkJHKlzsMVfGIqWJmixkYNNH0A5zTsmkXd64icOJWPSzoVrUFtVMgthFzjjibI260fkP7eNUah1chkxJQUl9r3RxbHbsPjXWclOQapDpu0p7LI/4mt7WG1qAmJSPuqPJz15Hxwe2gMMGaGnsz6TKkloKVFJHKoxxwsuY/Cam5461HWjnjeoSejiScVZe8Q7c"];
    [m appendString:@"TYLCxkV5RStJQvl2HuqOiSclSc4Uk4Ip2VgjIq2CDK5yJopZaV1bnMfdPeKcsKzgik0NplNlhRwrmhXcaZMSFsSFMujhKVYIPZRlGORAsfaWP0XavlaR1GzNbKlxl4RJazs4gnceY5jxrriHJjz4TM2I6l2O+gONLTyUk8jXDsQhYGDXQn0cdUrejvaVmu5U2C9DKjzH40D/AP18aepbHEy9VXn1CXFivHurKs5rWmTERPAb0oBWo2FbpziuE4zn/SDCCF6huI/0kdXDGbP/ADnf8CsT7gt156bJXlajn/as3m4NSFtxoqeqgRU8EdvuHefE0OSnzMlhhs/Zg71gA+09SRk5kzZuKVJVMf5DZI7qmFylSHhGbP2aT72O2oRT6Y8bhRslIwB3mpKzJ4UdYr7xqQZVh7wphKS02ANsUO9IGqU2u3LbbWOuWMDwpa6XRuDCW8tYASKpLVF2lXu8pZaytx5wIbSO8nAozPgYEDXXk7jDXoshP3O7PXt0KU4FFqMT+c/eX/aD8TVlajmtxISLfHV9m0ME957TUZoyCzZLGgIOzLfVNn8x5qV6nNQmobhkrPF21CkBcyzgs2PpBXWl"];
    [m appendString:@"06qO6SrfFLdFsg2vQ10vZJDrwcWg+Kvs0/IKPrQB0gXQqWtIVnFFk6R9WdGUGCMpU7w8XklP+SaGD7wuOMSvbstdwvBaQScEIHmeZ+FWHp2AGmEJSnlgAUDaRjmTdOtVvjKvUnb5Crg0nD6+4MR0NLedJylptPEpXpUtxgQDNnmWB0c2JLTQfcR7yt6syGyhCcAVGabsNzRGR1qGYqcfdUeJXwG3zohRbHUjeSkn+j/eirU/0iD2qT3EwKwsbUsqG+ge6pC/LY03WSDwrBSe41DKy9iVDA9TVW2aRWd63WaRdVVMy0Rf3qIukVmVFejSG0uMuoKFoUNlJPMVKuK7M0xkqBzVGhUJE5k1pYHtOX1+3L4lMH347h/G2eXqOR8RQhMRwqUk8q6W6SNITNTWbrIUJ52TGJW0pKDuPxJz4/qK5zu7Km1KCgQpJwaqARNFXDj7wHvr6rZdo8k7R5P2a/5VjkfhU0w5xoC0nINRetI3tVikpAytodcn05/Ko/RV0MiMI7isrSNvEU0y7kDRdW2uUMJ0uFKwQcHnSmoY4fgouzI95GESAO7sVSDo2yKlNOPNOOriSN2X0ltYPjXVd4M6"];
    [m appendString:@"4EciR1gnDiDTh8jR/pe5v2i6xLtDUQ9GcS4MHng7j1G1VVJYdttyfhuEhbDhSD3jsPwoy0vcUvpCVHfkaOnpOItYNwzO3bbNYudsjXGKoKYktJdQfAjl6cvSlwMVWv0fb0ZmnpNjeXlyCvjaB/6a/wDCs/GrLI3p4HImUy7WInhit8bVpilByqRIM5Su03qm+qQfeVzrNob4WutVnK/0ofW+t+WASSpagKIJkhEOGVZxwjCRXnB7Cesi5k+1XhEVs5QwnjWf5uQH/vdRG26ltvGcYoP0clRjOTXMlch0qB/lTsPnmn1+ugjxlIQr31CiKecyjLxiQuvr4XSqO2v3EczUF0XQVXDUzk9YJTGGEf1q2HwGT8Kh9SyiQRndR3qwOiuGIVgaeWMLey6r15fLFWb+8gcflDu5yw1GSyg4SgYqvdU3HgacVxUQ3qZ7qsGqt1hPJUtAPKpY54EqgxyYI6hfMmYlGSeNxKfioCjrpBkFu1xY4P3Gdh5mq1LnWX+2sk7rlt5+OaOtdOhyc012JCAR4AZqzLhgJwb0kxXQLEh+T7JBb45DiwCrGQ2OQ8yewV2P0U6HjacsyHHG+Oa8Ap51"];
    [m appendString:@"W6lHuz3CqW+jDpJtyVGkPtklI9qdJ7Vk7fD9q6oPChoJA5Cnqqgvq95i6m4sdo6jYhKRik1Het3DnNIqzTEUmFLx203kpS4khQzW66ScNQQDwZIOJHLyhzq1cz9099Iujal7o31scgKKVjdKhzB7DUfDme1xONQCXUkocT3KHOkLq9h46jdT7hE31Eq4Ug5J2AqftVkajNpkT0Bx47ho8k+feaT0vBS5KXNdTlDP3c9qv9ql5ThUokmr6ekEb2kXWkelYhJeURwjYDkBsBXL30hdJizah+tYrXDBuJKsJGzbv4k+v3h5nurpp886E+kKwM6m0zLtToAWtPEws/gcH3T+x8CaPdXvXErpbjVYD7TiK4tZK2l8lAoPkRioC46cctdtt+pLahQjPtp69A5NrHuq9CQfKi/UkN6K+8w+2pt5lZbcSeaSDii3o1gMXnQ8mE+2HENSnWyk/lUAv/8ARpbT8gqZo6r0kOJXkGQmSwHB2jcUqy4WJAION6Tu1nkaXvzkB4KMdz3mVntT/kV6QMpyOzcVQrtaGDCxMxfpFCQq1XoD3JSTGePc4ndJ9RmmFklmLLSrOx51JXhBuvR7dYnN"];
    [m appendString:@"2IlMxrvBQfex/aTQnZJYlQkLzladlUweQGigOCVnTHQXfBC1nAWV4ZmAxXd9ve+7/wCQFdLEb1w5oK6OICShZDrKgtB7iDkV25apiLjaodxbwUymEPD+5IJ+dMVNkRHUrhsxU91bisKFeFGi84q066mTfCAcpZbKz58hS+pppKV8J91A286g+jx8utXWUDsFIZB8cEn9qeTft58SLz66QhJ8uIZ+VefIw09ZnKwxiqTAtzLJOCyylHrjJ+eaG7nJW84pajUjdHy44vfYqJofujoQws9wqEnN3Bm6qMq4JYSSStYbHqcVcltUmNb0NI2CUgDyFU5ppPtWroSCMhKy4f7QT+uKtd54IY54Aqzn1ASqj0kxlqGf1TCyTv2VV97kF15WTnfJom1PP6xakhXuigq6u8LS1nmdhRKxk5MFYeMSKsqHZmtISmwSiM4HVnuAOB8zRzqZJkX1tgZ4lkJHrgfvSXR3YVNabl3h5B45HvoJ58CTt8dzT9LftGure32F1BPxz+1XzmwCU6qJnW/QJbUxLC5I4cFaghPkkY/zVmPOeNDPRzF9l0pDRjHEjiPrvT3VtwctWmLtc2U8TsOE8+gd"];
    [m appendString:@"6kIKh8xWkOBMA+poN9InSZZNGMKXKjy5y0q4FIjJThJ7ipRAz4DOO3FMujPpe0hr+Uu3Wx9+JdEJKzBmJCHFpHNSCCUrA7cHI7q5D19reXfmmW3HFFttACRnt5k+ZJJPiaDdOXmbZNWWq9W5xbcuHNaeaUk75ChkeRGQfAmg/GOftNIaJdnPc+lTnLNNXO2l3VA5IGAezupstVMTLiEj7pFCjbpiandjnPVym+MD+ZOx+RHwoofOxoLv7nDqGCtPPjWn04KX1X+mTGNP8+JZ9qT1NjYwN3PfPr/6KZ3efEt8J6bOktRozKStx11QSlAHaSadxXAbTExy6hH6Cubvpk6tdtzEHT6OLhkxlSOe3Fx8IJ78AHHdxZogIVBKqhssxDdnp16MZV2+rk6mbbWVcCXXmHG2Sf6ynA8zgUerUh1oOIUlaFDiSpJyCDyIPaK+Z7zqlOFWedddfQ41RNu+gp9imuLdFnkJRGWo5IZcSSEeSSFY8DjsqqWFjgw+o0y1ruWQ/wBJHTIiXdF+jN4YnfZv4HJ0DY/3AfEGoH6P6esjXyMR9yQ0vHmhQ/8AzXQWvbExqHT0u1P4AfR7iz+BY3Sr"];
    [m appendString:@"0PyzVH9BFtlQbtqhiW0ptxh9lhxJHJaePI/976oE225+sv8AF36fB7EU6U9LfW1pWWkf6ln7Rk47R2evKqXjkqaKFghaNiDzFdYXKGl1hQIztXOnSfa0WTVYUkcCJvEtI7OIY4v1Brr14zLaSznbI3SpR9ZKiO/wpCFMqHgoEH9arDT7y7fdXoLxxwuKaVnsIOP2qw2FFiW26nbCgc0Ca6jeya4ufAMJU/1w8lgK/eur5UiWuG1wYdaXkmNcRk4SrnXa/QlcRceji3jiyqMpcc+QOR8lCuErLJDsdl8H3hgK8669+itcvaNO3SCVZLTrbwHgoEH9BV6jhsQOpGUzLiO3OsVlZrWmYhOFejuOqNoSK+5s5Odckkfy54U/JOfWnEF0O6zgtA5DQW6fRB/2qQmpj2+G1Cjq/wBPDZQw2e9KEgZ9cZ9aH9GO+0ayfWTkohur8slI/esM87mnqhkYBhPMWcnehzUL3DGUAeZqbmLxnehHUz+Ns7Dc1FS5Miw4E36OQHdVPr/6MYnyKlAfsaNr1M4GihJ3oE6Ill6fepW+B1TYP/caIr2/gq3rnGbDJU+gSCujvG4RnzqHbt7l6vEa"];
    [m appendString:@"1M5AdV75H4UD7x+H609luABSjzo46J9PqRHVepLZD0rZoEbpaHL48/hRSdoxAHnmGVtsIdtS7ZEa5x1IQkDkAk4qubJg9IFtKs74PrwmunOjiw8H+tfb3VjAPdVA3qwvWjpmlWoIIVFdcWz4pCuJHxSRVEO07jKKwYMk7MsCA1ZoqB2NJHypaU21Ijux32w406hTbiDyUkjBHqCabWJ5D9niPNnKVtJI+FOlnetcciYJ4M4i6V+hPV2mLy+LTaJt5sy3CYsmI0XVJQeSXEp95KhyzjBxkHsqW6BegrUV11VCv2rbU/arLBeS+GZSeB2WtJylIQdwjIBJONhgZzt2GTg9ua1Ks5ofwlBzGzrLCuJh4lRPeTk01cOO2lnF47aZvr351cmLARCW4EoVvQPOX7TqaM2MkNoU4r12H6GiS9zENsLKlhIAJUT2DtNDmlmHJkmRdnEKSH1YbB7EDYUlqrQRsEd09RGXMsuzOh2xRt/ebT1Z9P8AbFU19KXo2n63sMS52Jj2i7WzjHUAgKkMqwSlOduIEZA7ckc8VaNhlBh1cZZwhw5T/VUhIIJNGqcOgECwNVm4T5up0xe3br9WIslz"];
    [m appendString:@"M7j4PZ/ZHA5nuwRtXYP0c9BytC6NcRckpRcp7ofkIByGwBhKM9pAznxJq1nSFbqOTTZ0gUVUCzrrzYMRCSAoHNQVytrIdckMNIQ44oKdKUgFZAxk95wAN+6pp1XOmUlexGaJiLZxIVbWUEEVRH0g7WudOjmOPtYbZcBH5lHl8B86v+Wpphh2S+oIbbSVKPhVV6hjquTkmS8j3nlE4/KOQHoKV1T7VxHNGpLbpQkR32iKFYII7O6h3pKQDqOO9j+PAaUfEjKT+lF19t67Pf3WSnDLx4keB7R+9Q3SDAU5bLRdACQhxyIs/wDmn96HQ3EdvXdgyF0g+eJyMvY4yB4iup/ogzj/AMQ3GEpWz0HIHilYP6E1y99WzoCIl7MZaYDj3soex7pdShKinz4VA1fv0WJhY6UYrOcJfZeb88oJ/ajKcPF7RmszrVYrAFbr768BtvTczJwNqa5pSlTaVZJ7B21r0ZW2eJs+/Po4YrjBjtk/iPECSPAY51aNt6BrnEsX1/q1zqXFrAbt6TlZB7XCNkj+Ub95HKpPVFkRbdFIkMtBtpMpLICRgfcJwPhWNYpRcT0iWq7gg5lc3FeAo1XuqpDj"];
    [m appendString:@"y+oZBW66oIQkcyScAUaXx7q47hzTTowsKr1qZd1eQVR4Rw2CNi4e30HzNRWdozLWST01Y06atSYSgOuW2lx5X5lnOf8AFRV7eBdUM0fdI0VVruYacBSow2XCO7i4jVYSRIuFwRCiILr7yuFKR+/cO01VOSWMufkAEc6Ws7mob2mMUkxGiFyFfy9ifM/pmuitE2EzJKEhvDDWM4G3lQ10caRFvhM26OkreWrjfdxupR5n9gKvvTFnZgQ0NoSAQNz313zmKXWY6kjbIqGGEoSMAUDdIfR8i7awgathECUwwY0lrH8VORwrB70jIPeMd1WQhISMVqrBojAYxFEYq2RGdrzBZDZH2XM/yn/FSBcSoZSoEGkcAU1fjLAK4boaXzKFDKD/AI9PhRq79gweoF6txzHq1Ab5pJTgHbUPJnXGMD7Tb3yB+NkdYn5b/EVHPakYScHrUnuLK8/pRTqqx7yF0rnoQgfeAzvUVOmpQlR4gMDJJ5CotVynzBwwLXNkE8lKR1SPUqx+lYTp96YoL1BKStAORCjE8H96uavkKQ1HkAoyP1PUeq0QHLn/ADIoNydTy+qj8QtqF/au/wDWI7E/y+Pb"];
    [m appendString:@"RgxBRGYS2gBKUjApVtYYYSzFZRHaSMAJFM5LijnJJPiaw7fLInKgsf0jYpNhwOBMPgcWM/Osm6lnCJfugnAc7D59xqMkuL3waaqmuJQpCkpdbIwpCxkEVGl84pbkYl7PH5H1hEqYhYyFg+tIuPpI55oTEdLzh+q56obvP2d4caD/AEnmPj6VspWo2Nlwo8gfmbkYz6EV6WnXK4zMq3RlTgQgdezsKayHGWGVvyXUNtp3UpRwBUG5M1GoFLdujMfzLdK/kAKj3rVcJbgduUpTygcgckp8hyFGbVqPl5gRpT/EYhfbou7OpZZSpuGhWUpIwXD+Y+HcPWmaooW2RiphNvQ0MYrVTISeVJsxY5MbUBRgSstc6PXemXERU/6pKSpnxUBkD15etAN0tTk/oXmTFNKC4t2aUARuMcKFD/z3rpSGw31gWUDPfURr2xtztG3iDGjoCnWeJKEJAy4XEHO3aTRa1xOa3PEG4XRz9b/RElMojlVx9ocvUXb3ste7gf1NpWPUUAfRik56UNOqBPvOFB/7FCuzLDa2LPYYFnbSFNQ4yGMHkrCcH4nPxrlXo70uvSf0pRp1KFJYjXJb0bxYWhS0"];
    [m appendString:@"H4HHpTrpgqYrVZuVx+c6zX92sA7c62VyrUDINMRGMtdMdfYVoxnCwarXpotgh9EsfhGCic2tX9yVCrfujIfhrQeWQaCOmyJ7T0VXVIGeoS28P7VDPyJpDVDn8o9pGwVH3nGGqXVqww0CpxZwlI7SdgKu7oZ0oI0ODbwnJ2W8rvPNR+NVvoHTj2oNRTLotBMK1lCSewurzwj0AUr0FdOdFtsDTS5RTj8KfSkuzial7bVlH/SfX7Jrh2O2klRixkISkZJ93YAetZ0BoJ2xhD1zZ/8AmHwOsQd+oB5N+ff47dlXpcejqFcelxrXVycbkMxIbaYkUpziQnI6xXYQkY4R379gpKy2oSL9LnPpJw8rgz586hgehKDUDYB9BHejrAiBHC3Eguq3UaLmkhKaSYQEJxtW6lY7aIOIkxLHJiqiMYpNRrTjNaKWc1xM4TcnJwOZNOnoaERus41lXyprG959GR25p084T9nnbhJqFwc5ksCMYkc1KC+LhVkpOD4GtlPE8yTQvKn/AFfqBfGcNPJwrwI5GnVwu7cSMJZyWkn3yN+EHtpG/VGqtm9xHU0xZhj3k06XFDAJApMM47BTW3XmNKaS"];
    [m appendString:@"424hxCuSknINS8dcd7GFpz41i1ldU24tk/eEcNVwRI91JAO1R8lJGaKFRG1IyCKirlGShJ5VGr0DquZNF6k4g0+OdR0lJ3NSUshKyM1GS3QAa8+QQZsJGEltKk77Ebgjsp1aryULEaYvOThLh/eo2ZLQkElQqOLzEgnKio9ya2PHai1WwDBailWXkQ+WUlOdqaPEb1A6bvJdaVGcXxhCsIXnmKmVr4gSDXrK23KDMKxCrFTGz2N6ZO86dPqO9NVbmriUxFoh3FEGmYyJN3aS6gLQPeIPLbcfMCoOIgE0XaKYPtjjuPuN/rTVAywi9xwphKsnOSaFp2i4EvpPtuvOuUiVCgORFNBGzpOeBZPYUhSx45HdRUsVpitEjMQBI6mSqsDJr361sBUiRHzoBBHfUVf7e3d7BcLS6QETI62So9nEkgH0ODUqsb02d91WKX1C5GYalsGVNoLQT+kuiT2C4NoF2flqmzOAhWFE8KU5HPCAPiaPdMRxGtjTYGNsmpKalLzC21bhQ3pvHHVN8I5Cs8rgx4uWHMeLI4T5VHtMIacUUjGTmnBcpNah31xlJuSANjWpV30l1nPetCvxqDJi2axk"];
    [m appendString:@"UgXPGsdZ41UmXVY/hBReUQCeFJO1KuJUkLeWkp93hSCNz3msWY5Lyx3AVm5rPVmpX5cyGPqxK01yrilKxkHhPKojSl7cda9lfWQrHuqNSOr18UtzJ5CgW3OKbUlxJwQazLly5H1m3pxmmGj9ujTluSbbNfsV0Cj1imEhbLiu9xk7HPekpPnTB++a8sW9w081fIqf/tWZ3iVjvUyvCh6E0opL81hMyCsCY2MFJOA6n8p8e40lC1Clay24VMvoOFNr2KTXntTU+nbDruX2Pv8AqJoUkWDjn7H/ALmYhdMunQvqZk6RbXgcKamNKZUD/cMVNs69s1xQDGu0Z8HlwOpV+hqKuLltubRRcIseUk8+tbCv1oPuuh9DSFKWbPHZWe1r3aALkYYyw/PP+IUUUE524MPZd6ZXuhXF5VAXe9NtNlbsuNGQOannQkfOgJ/Qmngs9QZIT3B1WP1pWJozT7Cgv2NC1D8TnvH51K0Vd5J/L/mF+HWvRjqbqu1uKKIi5N5ezsiKnDefFZ2+GaWgxrtdMPXdSIcEEFFvjEgO9wcXzUPDYeFOmGoUMBEdlPEdgEp51PQIjmA8/svGyfyj/Naejq3t"];
    [m appendString:@"hBxFdVctS5xMQWVNAEbHOdqnosglIyd6YpbxSzY4a9GoxxPOO2TmO3VZpNKSTWUgqNLtN5NEAgyY4iIwBRzpZgtQFPEYLitvIUK22MXnUtpGSogCj1ppLEdthHJCQKe0y85iWobjE8s7bVoayusDBNOxSercCta3FdidHqxjnSEhBW3kcxvThY3pJ55qMyp99wNtpGSTVWAI5llzkY7kQ69gkE0iXRnnQVqjX9jj31MZD/Uh08KesIAUvuHdnurZvU0dYyHR8axnuQMQDN4+M1CKGZSMwwLw76TW+O+hVWoGcZ6wfGkHdRsJG7qfjQzcs5dBYfaFapCQSM0muUnvoMd1PHB/ij0ps5qmOD99R/tNUN6xpPE3n+E/pDdUkZ+9XhJT30Aq1Uxz4l/9prw1XH71/wDaaG14jC+H1H8h/SXBpw8UBxzvcI+AFJ3ZeEKrGi1h3ScGTv8AboLvoonHyxSN8XhpeKb6rEwmXFrD6GVlqtf2klZPIH9KCIbgCRvRLr6YiHY7jMcVwpQgkn5fvVWQtSxF4AfSfI1nsMvN3ToTSZZtlm9U4BxbGpC/WiDemg9/ClJHuuo2Pr31X0G+NFQK"];
    [m appendString:@"XB8aLLXd0qSPfHxqzKrjaw4g8Ojbk4MHZsK+W9woz16ByIODTQ3CQg4ejvpPig0eyH2X0HODUatptKiUms5/F1McrxH08i2MOuYLtzHnDhqO+s9wbNSEW3XOSQXEiMg9q+fwFTjRA7actqT31erxVYPqJMFd5JsehQInbLZHiDiSC452rVz9O6pBKaTQtPfSwWmtWutUXaowJj2O9h3MczYJrdKN616xPfWDIQntoogdpjtpNPGUZqEcuTTYJKxSVq1XYv8AiKLbrneIsBDvvKU6vGw7B4nlnlREwTiQa2IyBLQ0lA4UmY4nYbN+faanV16I7EfhtrgutOx+EBCmlBSceYrKgc1rIoQYmS7FjkxMjNa8O+1bkYOK9jtq8pNcVuAMVrWw5Vw7nR+vASVEgAbkmgjVMmRdULbjEhsZDYzjPjUv0gXFdtsBWgHLqw2SOwYyf0qpJmqXEgpC1D1pDV3hfQZ6XwXjXu/8y+x4gjrvou1BfnClFxtkRlRypchxRI8QEg5PwrNl0k1p+EmNctYS7u6jZIbZDaQO7JJUfM04ul9lSSR1ignzqJEshRUSSc1jFkAwon0JdNfaAbm69gIQ"];
    [m appendString:@"MxUOLwgkJ71KJNSsW1QOEF+QfIHFBbl3U2NlYpk9qB8E8KlfGoUKPaTZp7OlOJZ6bfYEJ3UVHxVSTzNhTyQk+tVU7f5hP3yKbOXqYrm6r40bev8ALADRWe9hlmy1WhP3UIHrUROlQEtq6tAzjbFAS7m+rm4o+tPtNLduOorZb8lRkzGWseBWAflmhPz0IylPw1LFjxzOvbRHEKxQYoGOpjNox3YSKhtSLCY6zmiKQdlY5Z2oR1SvEde/OnrThZ8pry75PvKP6epRjdHVwAOFPKabHq4P2BrmptbmeLiIPhV+fSXlhvSkWNnd2ajPklKjVCNupwBik6sEZM954yr/ANfH3kxapdxQoFuS4B4nNGVmv10YxxFDg88GmHRxo7U+spHU6ctD8pCThyQRwMNf1OHYeQyfCuhNJ/R2jsMJd1Pf3XneZYt6QhA8ONYJPoBV9jt8ol9Xb4zTDF59X0Hf7dfnKvjatcSnDzbiPHGR8qdN6ujrP8VPxq4Lp0IaOLBRDk3aI6OS/aQ58QpNVjrHof1Da0uPwUM3yKnf7FHC+B4oPP8AtJ8qqUZexM6pvG6pttdm0/7hj9+og1qaMR/FT8ac"];
    [m appendString:@"t6kjdryfjVWyYDQWtvDzDiTwqTxFJSe4g8jUZKgy0Elqe+PPBrlYGHv8DevWDLtb1JFA3fT8a8vVUNHN9OPOqDfavKc8FwSf6kEfvTJ1m+LOFXBsDwB/zRgAfeZr+KvU42f2l/Sdb29sHMhPxqAu/SZbo6FEPgnzqmVWyU4cSLk6odydqUZssFJytsunvcJV+tWwv1l08TcewB/37Sf1H0tzJKlxrMyt91WwUkEhPwoes1o1Ne7j7ZMPVLcUCt6U6EY8hz9AKlosZDYCWwltPckYqViNDO7hHlV9y9AR2nxzU8lv2lr6Cv72kWGkwr68+4AOsSB9mrwweYroLQOroeq4KikBmY0AXWgdiPzJ8P0rka1sxUqBdfPxq0OhyapnXNtRCUspcc6tY70kYIpym4jAmJ5PxiFGcdjmdFr58qwdzWyufbWh54p2eTniK2HKvAbV6pnTGpbWi8Wh6EshKlDibUexQ5VzzquzyrfNdYkNKbWhWCDXS551UvS5c0TF/wCnaQsMZQFY3UO3fz5Ulra0K5buek/Dmrvqu+Ggyv8AaUu+VJUQc03KyO+lZlxiuSFNuAsO5+6rtpBRB5HNYTJg"];
    [m appendString:@"8T6fVbuHImCAo71siM2vYik+Ib1uh3hNQOJdhnqLC1tKHKkXrQnsFP4sxI5mnKpLSk8xVwQYuS6mDD9rUnJGaJehe1rkdKljSoEpZdXIP9iFEfPFJOrbUDR59HqCl7WsydjIiwiAfFagP0BrkGbFEX8nf8LQWuf5SP14/wDsvCRkINB+pySkg99GrjZWg4qHuOn13HKS91IPbjJpvUI7JhRzPl2ndFbLGcnfSDi3G+TrLZLRCkTpsiUsNR2EFa1kJ7APPc8h20d9Dn0Y48ZLN26RHEyn9lJtLDn2SP8A+qx98/ypwPE10Dp3TVosCVORI4MhYw7JcwXV+GeweA2p9JmpQCEHFW0um+FWPidx7UeZuZfhaf0r9ff/AImYcW32qC1DhR2IsVlPC0wygIQgdwA2FN5c9IBAwBUXcbo22klax8aE7zqDCVYWEIHaatbqVQTPp0z2H6wmkzUqUcLFNzJBPOq0i6ztUiStmPdI7ziFcKkpdBINTcW+JXjDgUPOllvVo0+jsTsRTXuibBq2OpcpkRrgE4bmsgBweCuxY8D6EVzTrSyXPSd5NtuzafeBUw+jJbeR3pP6g7iupm5fWs8S"];
    [m appendString:@"TmhPpF03H1hp2RanuFEpI6yG8Ru06BsfI8j4GrFA01/FeYu0ZFdhyn9v6f4nNDjiF8sU2WlBHKmq1SYUt6HLZU1IYcU062rmlSTgj404bdB5iuCYnr21W72mvVE/hNZDDh5JpwhVLo8attgDcY2RFeJ54p9HgOEjLhpVkpGM0+jrQDzFWAEBZc0c2y2grHESfWr56AbAn60cuim/ciN4ScfjUMD5ZNVHp1oPPpwMiuqdCWgWbSsSOU8Lzieue7+JQ5egwKc09YJzPLea1bLXtz3JlWN60rZXdWOHen55OYFbVjGKyK6dG2sLmLbaVqSrDr3uN+HefhVLX6SXEqSTkUV9MN4cavKYqQShhsDHidzVYyrp1qjxHFY2uvyxX6T6J+G/HFKBb7tz/iQd6t7UgqDrfFvse0VCGFMhkllwuN/lVzFGCVNvL3xvTpNuZdTjHOs1dx6nrS6oPVAdt/JwsFKu6lQfGiqTppt3JTsaYP6eeZBOSRRMH3E741fs0gllQyQTTdUhxB5mpV+AtGxBpk9HxkEVHUup3dGIJnrHOrx+jEUuw79J/EXmWvQJUf3qilxj2Vcv0XpHVvX6ArIKgw+k"];
    [m appendString:@"f9yT+1XpI+IJlfiJSfG2fl/cS+G1Y5dtKKWltHEdzTZB3rd9tTjW2a1FbifK2AzI+fP4QSVYAoWvV+bZQpRdShI5qUcCiCfYn5w4RL6gE7ng4jS9q0vaLetL/Ue0yU7h+RhagfAck+gpN1vtbCjA+sbRqKxluT9JXrULU1/IVa4HVMq/+3NJbbx3pGOJXoMeNLSOhuBdWj/xRqC6zkn7zENfsrJ8DjKz8R5VaLz7SNycmo6bcQAdwBUpo6q/U53H7y519x4r9I+3+e5S2ofo5aAdaP1RJvFokJ+44iT1yQfFKxn4EVWt96PekvQ8lMmJNe1BZ21ZWqISpxCO8tHKtv5SoV0nOuIUo4VTMTTn71VetX7EZp8hfX8x3D7wN0RdWLhaG1ocCiRvv21JzPcXxjsp5c7VAmPKlNJESYdy80AOI/zDkr9fGoGdLfgOCPckJSFnCHUn3F+R7D4GgJuq4br6yX2XHcnf0lP/AEgtLoamx9Ww28IlKEecB2Oge4v+4DB8Ujvqr2xiumdasQ5+h72zMdQIxhLcKydkqSOJKvPiArmFDnugnY00OeZ6DxdzPTtb+HiPm1pHaK2MgDtqPKlK"];
    [m appendString:@"OBSiG1Hmagma6oWjtMlROxp9BWtaxvUYhGKlrWj3hXKZFte0S1eiG3i46lgRFjKXHkhXlnJ+QNdUrwc9grm/6PyQdaws9gWfgg10cs1p6bhMz5/5xs6gD7RM7VjNeNepqY09Ww5VpW42FdOgX0r6dMkKvDaFKQlAD4QnJTj8WO7FUq8i3yk8cZ91BUcIEhhbIWf5VKASr0Jrq8N8WeLkRypncoMOVGVFkxmXmFDBbcQFJI7sHas3V6YOciei8Z523SKExnH39pyW8l6K4UrCkKHYRTiJdlNHC81c+p+i22ykKXZXzAX2MLBcYPkCcp/tPpVRaq0pdrE6frCEthvOA8k8bKv7vw/3AVktU9fc9tovO6XVja3BklCvLCwApQFOHprLiOYoCc6xhQ4sp7Qew+RrZNwcQPvGpFhmi2jR/Uhk9cS2okioaQBmkVXAq5qpu5MBzk1UnMaqqKCKkDej7oBlCPr5UfOBKhOJx3lJSofoarf2pHaaI+iy4IjdI9idCsccoMnyWkp/cVCHa4MD5Sr4uitT/af25nVaDThleDjO1NUnYVniONq1lODPkDDMcuvpQNqj5U/APvU1ukrqUKUe"];
    [m appendString:@"yg29ahZYQpb76WUd6jjPlQrtSE7MLRpmsOFGYQXC7oQDlWTQver6ltC3X30MNJGVFSsYHiaHZdw1Xd0lGlNKXC4KVykvgR2B48bmMjyzUHJ6DOkXVjgd1dq6121gnIiQm1vhPnnhBPiSaV3228oOJorp6af9ZwPt2f2hHbtTWm4oK4NxYkJzzbcCqkm5yDuFg+tBcj6M0eG31tu1zOZlp5LXDSBn+1QNQFx0t0v6OXxhuPqm3IO6oasvgd/ArCj6cVRi1O+Zf4emt+Rv1ls+1Z5GmlwDE6O5EmNhxlwYUD+vgfGgTSuuIlxUqO8VsSUHDjLqShaD3FJ3FGTTjchGUKByOw1dLA/EDZQ9J5lB9N9u1fYUth24PTdMyFjqFJASEK5hDoHNQ7Cdj4GqvRIdWe6uxZsSLOt8i03aMmVAlNlt1tXak9o7iOYPYa5S1RYzp7VNyspd64Q5Cm0ufnTzST44Iz40UYxxPReK1ItBRhyP3iMPkCafJUMUxZ2FPmC3+IFR7KoV5noFsCjqKJ35Cpi0R33XEhDaj6Uxi+0qXhlttI8Uk0Z6MaUzcGXpzheQlQJaA4UkZ5GiJWZn6rVgKTLf"];
    [m appendString:@"+jzpyai8G7PIUliO0ocWNipQwB8yau9Yr0FMRNuj+wNNtRVNpU0htICQkjIwBXlitatAi4nzbWaltTaXIxEzXu2skbV499EzFZjFbDlvWdsZxXsDsrp0lHDgU2XlRpVxWTWuBilWO4wqjERKe6kJMVmQ2pt5tLiFDBChkGnZxWpx2UMqIQMR1Kp1r0S26cHJNic+rX1bloJ4mVnxQdh5jFUpqvSl8sTqhcLa8hAOA9GPG2fQ7iuvlAUyn2+PMaUh5tKwRggjNLWaVTyOJtaLzup03GcicPypHUk+5MX5Nf70yVcCf+W+j+tOK6t1D0Y2WYtbiIgaWd8t7UH3DooQknqnFY7iM0uaGE36vxNn5pQaZfEf4iR5mpPTlwMLUNtmcY+wmMubHuWk1aMjowfTnCG1jxRUbL6N5KUkiE0SNwQO2gMjCPJ+IKnBUjv7zp44yccsmsE0nAUpy3x3FDClNIJ8ykZrZRxWjPn8yqExI3d3HdWGbXZ47/tCIMUPf9TqgVD1PKtFO8I502elBOSVVHo7xzO9XWZKuy2x4476aSJ+M8hUHLujaAffqIl3VxzZsetc1pMlapNXG5cIV729Qa7k"];
    [m appendString:@"ok5OaYuLW6shbg4u7NJuNH8JoROYcKBEtR2WwajbH1tb2nnkjCJAHA8j+lY94eXKqw1WxqbQJM+Gh+/WQbqUgj2iOP5k8lD+YeoqzlBY23pB55bYRkcQ484PlQyik5Map1DJ6TyPpKYndOKTBUm02VxUpScJclKT1aD38KclXlkCqklyJM2Y/NmOqfkvuFx1xXNSick1bnTVoK2RIrurrEymMylY+sIiBhKOI4DqB2DJAUPEHvqpfa7ej7zoouMT1Pj1oKb6RjPc8yDTlPPxpNm4W3OEuCnbRjPfw1g1QzSU8cyWsU1CFhDuCO+jCCUcSVtnIqvw0UHKaIrBOUkBtefCi1vjiJaqgMNyzsHoruP1joSAVK4lxwY6v7eXyIojVVa/R2kLdsFyZUTwoeQpPqkg/oKsxYwa1a2yoM+cayv4d7L94mc14VtvWfKrxaaHI3zWw8Kwd68Nq4To9VSfWFB35UoTtSL2KSPHMOIoogpyK0PfmkW3eFXCeRpRRxUbsiTjE2Na1qVVnNdmdMEBQ3pF2OhQ5CnArCjUmcDI9cJs80ikXLe0fwCpMDJzWSmhsoMIrkRFlPAwhH5U4pN00sva"];
    [m appendString:@"mzyjiqGXEYzX+BJOaGbjcXFOFCDgd9TV1V9mqhGWcrXQTDIBGF71DbLXtMkFx8jKWUDiWfTsHiaEbnqq63DKIn+hYP5N3CP6uz0qL1EUvakldvAUo+A/3paIyCOVJmxnOJpiuusA9mN2YznW9f1rvW5z1nGeLPnzqdg3u9RcAviQjueGT8RvSTTIAxinLbHhVghEq1obuTcLUSXgBJjLbV2lPvD/ADWGdS6XnLdZZvtsU40socR7UgKQoHBBBOQQaj0hthtTi8BKRxKPgOdcd3B5NwvE2eUg+0yXHRkZ2Usn96Oo45hNJpF1LEDidH9OetdPw9HXGwwLjFuFxuTXs/Vx3AsMoJBUtZGwOBgDOcnwrmcQwTyp820Ep2GPKlmmxzxVxwMT0Om0ddC47MYIhFlaXgjiCTuB2jtopFnkNNIkw1qW2oBSd+YPKm0JCSoBQyDVlaFgtyLUqIRxdSco/oO+PQ5qe4HWudOBZXx9YEQprqFBuSgjxxRRYmkSH0cChuaLmtEsTXxxNjGdzijzTujrDaoplRre37U3hQcUSojHPAOwqVrMUs85Xs5HP2lo9DliVZNHNqewH5iuuUPypxhI"];
    [m appendString:@"PjzPrReuhTo9uZdbcgOKzgcbefmP3orXyrUrxsGJ4u92ews3Zmud6xWDXjmrwUyTXuytc1uOVTiRP//Z"];
    NSData *d = [[NSData alloc] initWithBase64EncodedString:m
                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (d.length > 0) {
        g_avatarImg = [UIImage imageWithData:d];
        L("avatar: b64 %lu 字符 -> JPEG %lu 字节 -> %s",
          (unsigned long)m.length, (unsigned long)d.length,
          g_avatarImg ? "解码OK" : "解码失败");
    } else L("avatar: base64 解码失败 (%lu 字符)", (unsigned long)m.length);
    return g_avatarImg;
}

static UILabel *mkLabel(NSString *t, CGFloat sz, CGFloat w, UIColor *c, CGRect f, UIView *p) {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.text = t; l.font = [UIFont systemFontOfSize:sz weight:w];
    l.textColor = c; [p addSubview:l]; return l;
}
static UIView *mkCard(CGRect f, UIView *p) {
    UIView *c = [[UIView alloc] initWithFrame:f];
    c.backgroundColor = DK_CARD;
    c.layer.cornerRadius = 13;
    c.layer.borderWidth = 0.5;
    c.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
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
    s.thumbTintColor = [UIColor colorWithWhite:0.95 alpha:1];
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
    c.layer.cornerRadius = 16;
    mkIcon(emoji, bg, CGRectMake(8, (f.size.height - 40) / 2, 40, 40), c);
    mkLabel(title, 16, UIFontWeightBold, DK_TEXT, CGRectMake(58, 0, f.size.width - 130, f.size.height), c);
    UIButton *go = [UIButton buttonWithType:UIButtonTypeCustom];
    go.frame = CGRectMake(f.size.width - 56, (f.size.height - 40) / 2, 40, 40);
    go.backgroundColor = DK_TEAL; go.layer.cornerRadius = 20;
    [go setTitle:@"▶" forState:UIControlStateNormal];
    [go setTitleColor:[UIColor colorWithRed:0.05 green:0.05 blue:0.07 alpha:1] forState:UIControlStateNormal];
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
    // ⚠️ 必须初始化: 所有 addTarget:g_helper 的 target 为 nil 时点击/拖动全部失效
    if (!g_helper) g_helper = [[DK3Helper alloc] init];
    CGFloat W = MIN(272, win.bounds.size.width - 30);
    CGFloat x0 = (win.bounds.size.width - W) / 2;
    CGFloat y = 76;
    CGFloat pad = 12, cw = (W - pad * 3) / 2, ch = 52;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(x0, 76, W, 500)];
    panel.backgroundColor = DK_PANEL;
    panel.layer.cornerRadius = 20;
    panel.layer.shadowColor = UIColor.blackColor.CGColor;
    panel.layer.shadowOpacity = 0.55; panel.layer.shadowOffset = CGSizeMake(0, 6); panel.layer.shadowRadius = 16;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
    panel.hidden = YES;
    [win addSubview:panel];
    g_panel = panel;

    // 面板左上小彩虹头像
    {
        CGFloat asz = 22;
        UIView *abox = [[UIView alloc] initWithFrame:CGRectMake(pad, 11, asz, asz)];
        CAGradientLayer *rg = [CAGradientLayer layer];
        rg.frame = abox.bounds;
        rg.type = kCAGradientLayerConic;
        if (@available(iOS 12.0, *)) rg.startPoint = CGPointMake(0.5, 0.5);
        rg.endPoint = CGPointMake(0.5, 0.0);
        rg.colors = @[(id)[UIColor colorWithRed:1.00 green:0.30 blue:0.42 alpha:1].CGColor,
                      (id)[UIColor colorWithRed:1.00 green:0.90 blue:0.30 alpha:1].CGColor,
                      (id)[UIColor colorWithRed:0.34 green:0.88 blue:0.42 alpha:1].CGColor,
                      (id)[UIColor colorWithRed:0.24 green:0.72 blue:1.00 alpha:1].CGColor,
                      (id)[UIColor colorWithRed:0.55 green:0.40 blue:1.00 alpha:1].CGColor,
                      (id)[UIColor colorWithRed:1.00 green:0.30 blue:0.42 alpha:1].CGColor];
        CAShapeLayer *m2 = [CAShapeLayer layer];
        UIBezierPath *pp = [UIBezierPath bezierPathWithOvalInRect:abox.bounds];
        [pp appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectInset(abox.bounds, 2.0, 2.0)]];
        m2.path = pp.CGPath; m2.fillRule = kCAFillRuleEvenOdd;
        rg.mask = m2;
        [abox.layer addSublayer:rg];
        UIImageView *av2 = [[UIImageView alloc] initWithFrame:CGRectInset(abox.bounds, 3.2, 3.2)];
        av2.image = dk_avatar_image();
        av2.contentMode = UIViewContentModeScaleAspectFill;
        av2.layer.cornerRadius = av2.bounds.size.width / 2;
        av2.layer.masksToBounds = YES;
        [abox addSubview:av2];
        [panel addSubview:abox];
    }
    mkLabel(@"弹壳战机 · 全功能", 15, UIFontWeightBold, DK_TEXT, CGRectMake(pad + 28, 12, W - 108, 20), panel);
    g_statusSub = mkLabel(@"初始化中…", 9, UIFontWeightRegular, DK_SUB, CGRectMake(pad + 28, 30, W - 108, 14), panel);
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(W - 40, 14, 26, 26);
    closeBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10]; closeBtn.layer.cornerRadius = 13;
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor colorWithWhite:0.85 alpha:1] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [closeBtn addTarget:g_helper action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:closeBtn];

    y = 52;
    mkToggleCard(CGRectMake(pad, y, cw, ch), @"🎯", DK_RED,   @"怪物自杀", @"全场怪物即死", g_killOn, g_helper, @selector(killSw:), panel);
    mkToggleCard(CGRectMake(pad*2+cw, y, cw, ch), @"🛡️", DK_BLUE, @"无敌", @"绝对无敌+满血", g_invOn, g_helper, @selector(invSw:), panel);
    y += ch + 7;
    mkToggleCard(CGRectMake(pad, y, cw, ch), @"⏱️", DK_GREEN, @"游戏加速", @"战斗整体变速", g_speedOn, g_helper, @selector(speedSw:), panel);
    mkToggleCard(CGRectMake(pad*2+cw, y, cw, ch), @"🚫", DK_GOLD, @"免广告", @"跳过视频直发奖", g_noAdOn, g_helper, @selector(noAdSw:), panel);
    y += ch + 7;
    mkGoCard(CGRectMake(pad, y, W - pad*2, 54), @"⚡", DK_GOLD, @"一键通关", g_helper, @selector(passTap), panel);
    y += 60;
    mkStepCard(CGRectMake(pad, y, W - pad*2, 54), @"🧭", DK_BLUE, @"加速倍率", @"点 ± 调整 (开加速后生效)",
               &g_spdVal, g_helper, @selector(spdDec), @selector(spdInc), panel);
    g_spdVal.text = [NSString stringWithFormat:@"%.1fx", g_speedMult];
    y += 60;
    mkLabel(@"弹壳战机 1.1.7 · v3.7 · 昆哥儿", 9, UIFontWeightRegular,
            [UIColor colorWithWhite:0.45 alpha:1],
            CGRectMake(pad, y, W - pad*2, 14), panel).textAlignment = NSTextAlignmentCenter;

    CGFloat ph = y + 26;
    // BUG 修复: 面板高度超出可用高度时整体缩放, 避免底部被裁掉
    CGFloat availH = win.bounds.size.height - 76 - 34;
    if (ph > availH && availH > 120) {
        CGFloat k2 = availH / ph;
        panel.transform = CGAffineTransformMakeScale(k2, k2);
        ph = availH;
        L("UI: 面板超屏 → 缩放至 %.2f (%.0f→%.0f)", k2, y + 26, ph);
    }
    panel.frame = CGRectMake(x0, 76, W, ph);
    g_panelPan = [[UIPanGestureRecognizer alloc] initWithTarget:g_helper action:@selector(panelPan:)];
    g_panelPan.delegate = g_helper;
    [panel addGestureRecognizer:g_panelPan];

    // ══ 悬浮球: 头像 + 抖音同款彩虹环 (conic 渐变, CAShapeLayer EvenOdd 环形 mask) ══
    CGFloat bs = 62;
    UIButton *ball = [UIButton buttonWithType:UIButtonTypeCustom];
    ball.frame = CGRectMake(win.bounds.size.width - bs - 16, 150, bs, bs);
    ball.backgroundColor = UIColor.clearColor;
    ball.layer.shadowColor = UIColor.blackColor.CGColor;
    ball.layer.shadowOpacity = 0.45; ball.layer.shadowOffset = CGSizeMake(0, 3); ball.layer.shadowRadius = 7;
    ball.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:ball.bounds].CGPath;

    CGFloat ringW = 4.0;
    // ① 彩虹圆锥渐变环
    CAGradientLayer *rainbow = [CAGradientLayer layer];
    rainbow.frame = ball.bounds;
    rainbow.type = kCAGradientLayerConic;
    if (@available(iOS 12.0, *)) rainbow.startPoint = CGPointMake(0.5, 0.5);
    rainbow.endPoint = CGPointMake(0.5, 0.0);
    rainbow.colors = @[
        (id)[UIColor colorWithRed:1.00 green:0.30 blue:0.42 alpha:1].CGColor,  // 红
        (id)[UIColor colorWithRed:1.00 green:0.62 blue:0.24 alpha:1].CGColor,  // 橙
        (id)[UIColor colorWithRed:1.00 green:0.90 blue:0.30 alpha:1].CGColor,  // 黄
        (id)[UIColor colorWithRed:0.34 green:0.88 blue:0.42 alpha:1].CGColor,  // 绿
        (id)[UIColor colorWithRed:0.24 green:0.72 blue:1.00 alpha:1].CGColor,  // 青蓝
        (id)[UIColor colorWithRed:0.55 green:0.40 blue:1.00 alpha:1].CGColor,  // 紫
        (id)[UIColor colorWithRed:0.90 green:0.35 blue:0.85 alpha:1].CGColor,  // 品红
        (id)[UIColor colorWithRed:1.00 green:0.30 blue:0.42 alpha:1].CGColor,  // 回到红(闭环)
    ];
    rainbow.locations = @[@0.0, @0.14, @0.28, @0.43, @0.57, @0.71, @0.86, @1.0];
    // 环形 mask (EvenOdd): 外圆减内圆 → 只留环
    CAShapeLayer *ringMask = [CAShapeLayer layer];
    UIBezierPath *p = [UIBezierPath bezierPathWithOvalInRect:ball.bounds];
    [p appendPath:[UIBezierPath bezierPathWithOvalInRect:
                   CGRectInset(ball.bounds, ringW, ringW)]];
    ringMask.path = p.CGPath;
    ringMask.fillRule = kCAFillRuleEvenOdd;
    rainbow.mask = ringMask;
    [ball.layer addSublayer:rainbow];
    // ② 头像 (内圆, 略小于环内径)
    UIImageView *avatar = [[UIImageView alloc] initWithFrame:CGRectInset(ball.bounds, ringW + 1.5, ringW + 1.5)];
    UIImage *img = dk_avatar_image();
    avatar.image = img;
    avatar.contentMode = UIViewContentModeScaleAspectFill;
    avatar.layer.cornerRadius = avatar.bounds.size.width / 2;
    avatar.layer.masksToBounds = YES;
    avatar.userInteractionEnabled = NO;
    [ball addSubview:avatar];
    // ③ 无头像时的兜底文字
    if (!img) {
        [ball setTitle:@"弹" forState:UIControlStateNormal];
        [ball setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        ball.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        ball.backgroundColor = DK_TEAL;
        avatar.hidden = YES;
    }
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
    L("== DKZJ v3.7 启动 (启动计数 %d/3) — unity base=%p slide=%d",
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
