
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
