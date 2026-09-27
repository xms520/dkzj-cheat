
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
enum { RS_WAIT_DOMAIN=0, RS_HF, RS_HFB, RS_AD, RS_COR,
       RS_C1, RS_C1b, RS_C2, RS_C2b, RS_C3, RS_C3b, RS_C3c,
       RS_M1, RS_M1b, RS_M2, RS_M2b, RS_M2c, RS_M3, RS_M3b, RS_M4, RS_M4b,
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
                m_Char_AddStatus    = mof(k_Char, "AddCharacterStatus", 1);
                m_Char_getCurrentHp = mof(k_Char, "get_CurrentHp", 0);
                m_Char_setCurrentHp = mof(k_Char, "set_CurrentHp", 1);
            }
            L("A[M2c] absInv=%p status=%p curHp=%p/%p",
              m_Char_AddAbsInv, m_Char_AddStatus, m_Char_getCurrentHp, m_Char_setCurrentHp);
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
            if (g_imgAD && !k_Ad_Local) k_Ad_Local = cn(g_imgAD, "GorillaAd.Runtime", "LocalRewardedVideoAd");
            if (k_Ad_Local) m_Ad_Show0 = mof(k_Ad_Local, "Show", 0);
            L("A[M4b] Game.SetTimeScale=%p adShow0=%p", m_Game_SetTimeScale, m_Ad_Show0);
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
