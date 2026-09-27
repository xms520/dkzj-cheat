
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
