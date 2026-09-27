
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
