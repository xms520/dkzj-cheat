
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

static __block BOOL g_installed = NO;   // 防重入 (同一进程多次触发)

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
