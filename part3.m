
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

