
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
