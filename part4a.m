
// ───────────────────── 通用 MethodInfo 热替换 (零 __TEXT patch) ─────────────────────
// 原理: il2cpp MethodInfo 里的 methodPointer 是【数据段函数指针】, 改写它
//       不影响代码段、无需 mprotect 代码页、无 icache 风险。
//       HybridCLR 解释器执行 call 时会读取该指针 → 替换对热更方法同样生效。
// ⚠️ 不采用 inline hook: arm64 序言含 ADRP/ADD 等 PC 相对指令, 覆写极易踩雷。
//
// MethodInfo 布局 (il2cpp v31, arm64) 实测探测:
//   +0x00 methodPointer (指向 __TEXT)
//   +0x10 name (const char*)
// 探测法: 用 method_get_name() 的返回值做【指针相等】比较定位 name 字段,
//         同时找第一个落在 __TEXT 的指针作为 methodPointer。

typedef struct {
    uintptr_t  *slot;        // methodPointer 所在地址
    uintptr_t   orig;        // 原函数指针
    void       *mi;
    const char *name;
    int         hits;
} dk_hook_rec_t;

static dk_hook_rec_t g_hooks[8];
static int g_hookN = 0;

// 安全读指针指向的字符串是否等于 want (用 SIGSEGV 守卫保护)
static int ptr_eq_cstr(uintptr_t v, const char *want) {
    if (!v || !want || v < 0x1000) return 0;
    int ok = 0;
    if (DK_GUARD_BEGIN() == 0) {
        const char *s = (const char *)v;
        ok = (s == want) ? 1 : 0;                 // 指针相等
        if (!ok) ok = (strcmp(s, want) == 0) ? 2 : 0;  // 内容相等
    }
    DK_GUARD_END();
    return ok;
}

static void *dk_hook_method(void *mi, void *replacement, const char *tag);

// 找 methodPointer 槽位; 返回槽地址
static uintptr_t *find_methodptr_slot(void *mi, const char *tag) {
    if (!mi) return NULL;
    const char *want = (I.method_get_name) ? I.method_get_name(mi) : NULL;
    uint8_t *p = (uint8_t *)mi;
    int nameOff = -1, ptrOff = -1;
    int g = DK_GUARD_BEGIN();
    if (g == 0) {
        for (int off = 0; off <= 96; off += 8) {
            uintptr_t v = *(uintptr_t *)(p + off);
            if (!v) continue;
            if (nameOff < 0 && want && ptr_eq_cstr(v, want)) { nameOff = off; continue; }
            if (ptrOff < 0 && dk_ptr_executable(v)) ptrOff = off;
        }
    }
    DK_GUARD_END();
    if (ptrOff < 0) {
        L("hook[%s]: methodPointer 未定位 (nameOff=%d want=%s)", tag, nameOff, want ? want : "?");
        return NULL;
    }
    if (nameOff < 0 && want) {
        // name 字段未能用指针比较命中 → 布局异常, 仍尝试 (打印告警)
        L("hook[%s]: ⚠️ name 字段未命中, methodPointer@%d (方法名=%s 不可信)", tag, ptrOff, want);
    }
    L("hook[%s]: name@%d methodPointer@%d (name=%s)", tag, nameOff, ptrOff, want ? want : "?");
    return (uintptr_t *)(p + ptrOff);
}

static void *dk_hook_method(void *mi, void *replacement, const char *tag) {
    if (!mi || !replacement || g_hookN >= 8) return NULL;
    uintptr_t *slot = find_methodptr_slot(mi, tag);
    if (!slot) return NULL;
    // 确保页可写 (MethodInfo 通常在 il2cpp metadata/GC 区, 多数已可写)
    vm_prot_t cur = 0, max = 0;
    vm_address_t pg = (vm_address_t)((uintptr_t)slot & ~(uintptr_t)(vm_page_size - 1));
    vm_size_t sz = vm_page_size;
    if (vm_region_64(mach_task_self(), &pg, &sz, &max, NULL, NULL, NULL, NULL) == KERN_SUCCESS) {
        if (!(max & VM_PROT_WRITE)) {
            kern_return_t kr = vm_protect(mach_task_self(), pg, sz, FALSE, max | VM_PROT_WRITE);
            if (kr != KERN_SUCCESS) L("hook[%s]: vm_protect 失败 (kr=%d)", tag, kr);
        }
    }
    g_hooks[g_hookN].slot = slot;
    g_hooks[g_hookN].orig = *slot;
    g_hooks[g_hookN].mi   = mi;
    g_hooks[g_hookN].name = tag;
    g_hooks[g_hookN].hits = 0;
    *slot = (uintptr_t)replacement;
    L("hook[%s]: 安装成功 %p → %p (slot=%p)", tag, (void *)g_hooks[g_hookN].orig, replacement, slot);
    g_hookN++;
    return slot;
}

static void dk_unhook_all(void) {
    for (int i = 0; i < g_hookN; i++) {
        if (g_hooks[i].slot) *g_hooks[i].slot = g_hooks[i].orig;
    }
    if (g_hookN) L("hook: 全部 %d 个已还原", g_hookN);
    g_hookN = 0;
}

// ───────────────────── ⑤ 免广告实现 ─────────────────────
// 主方案: 替换 ADModuleMgr.CheckAndPlayVideo(callback, source)
//         → 跳过视频, 直接调用传入的 callback(发奖委托)
// 辅方案: 替换 GorillaAd.Runtime.LocalRewardedVideoAd.Show() → 触发 OnRewarded/OnClosed
// 兜底:   若 CheckAndPlayVideo 无参数回调, 读实例字段 _onClose 委托并 Invoke
static uintptr_t *g_adSlot = NULL;

// 判定对象是否为委托 (C# Delegate): 类名含 Action/Func/Callback/<> 或继承 MulticastDelegate
static int looks_like_delegate(void *obj) {
    if (!obj || !I.object_get_class || !I.class_get_name) return 0;
    Il2CppClass *k = (Il2CppClass *)I.object_get_class(obj);
    if (!k) return 0;
    const char *nm = I.class_get_name(k);
    if (!nm) return 0;
    if (strstr(nm, "Action") || strstr(nm, "Func") || strstr(nm, "Callback")
        || strstr(nm, "Delegate") || strstr(nm, "<>") || strstr(nm, "Predicate")) return 1;
    // 沿父链检查 MulticastDelegate
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

// 替换实现: 参数扫描 → 找 delegate 参数 → 立即 Invoke (模拟"广告已看完")
// ⚠️ 只能 hook 签名已知的方法; 参数个数不足时安全跳过。
static int  g_adHooked = 0;
static void *ad_hook_self = NULL;   // 记录最近一次实例 (供 _onClose 兜底)

static void ad_replacement_2(void *self, void *a1, void *a2) {
    g_hooks[0].hits++;
    ad_hook_self = self;
    static int l = 0;
    if (l++ < 6) L("⑤ noAd: 拦截 CheckAndPlayVideo(self=%p a1=%p a2=%p)", self, a1, a2);
    int fired = 0;
    if (a1 && looks_like_delegate(a1)) fired += delegate_invoke(a1);
    if (a2 && looks_like_delegate(a2)) fired += delegate_invoke(a2);
    if (!fired && self && off_AD_onClose > 0) {
        void *d = *(void **)((uint8_t *)self + off_AD_onClose);
        if (d) fired += delegate_invoke(d);
    }
    if (l <= 6) L("⑤ noAd: 发奖回调触发 %d 次", fired);
}

// LocalRewardedVideoAd.Show() (无参) → 直接触发 OnRewarded/OnClosed
static void ad_replacement_show0(void *self) {
    if (g_hookN > 1) g_hooks[1].hits++;
    ad_hook_self = self;
    static int l = 0;
    if (l++ < 6) L("⑤ noAd: 拦截 LocalRewardedVideoAd.Show(self=%p)", self);
    // 委托字段名: OnRewarded / OnClosed / OnShowSuccess
    const char *fns[] = { "OnRewarded", "OnClosed", "OnShowSuccess" };
    int fired = 0;
    for (int i = 0; i < 3; i++) {
        int32_t off = foff((Il2CppClass *)I.object_get_class(self), fns[i]);
        if (off > 0) {
            void *d = *(void **)((uint8_t *)self + off);
            if (d && looks_like_delegate(d)) fired += delegate_invoke(d);
        }
    }
    if (l <= 6) L("⑤ noAd: LocalShow 发奖 %d 次", fired);
}

static void ad_hook_install(void) {
    if (g_adHooked) return;
    if (!g_parsed) return;
    if (m_AD_CheckAndPlayVideo) {
        if (dk_hook_method(m_AD_CheckAndPlayVideo, (void *)ad_replacement_2, "ADMgr.CheckAndPlayVideo"))
            g_adHooked++;
    }
    if (m_Ad_Show0) {
        if (dk_hook_method(m_Ad_Show0, (void *)ad_replacement_show0, "LocalRewardedVideoAd.Show"))
            g_adHooked++;
    }
    L("⑤ noAd: hook 安装结果 hooked=%d (CheckAndPlayVideo=%p LocalShow=%p)",
      g_adHooked, m_AD_CheckAndPlayVideo, m_Ad_Show0);
}

static void ad_hook_remove(void) {
    dk_unhook_all();
    g_adHooked = 0;
    L("⑤ noAd: hook 已移除");
}
