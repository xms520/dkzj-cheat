
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
