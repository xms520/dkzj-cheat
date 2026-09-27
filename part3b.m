
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

static void ad_hook_install(void) {
    if (g_adHooked || !g_parsed) return;
    if (m_AD_CheckAndPlayVideo) {
        void *s = dk_hook_method(m_AD_CheckAndPlayVideo, (void *)ad_replacement_2, "CheckAndPlayVideo");
        if (s) { g_ad_mp_slot = s; g_adHooked++; }
    }
    if (m_Ad_Show0) {
        if (dk_hook_method(m_Ad_Show0, (void *)ad_replacement_show0, "LocalAd.Show")) g_adHooked++;
    }
    L("⑤ noAd: hooked=%d (play=%p show0=%p)", g_adHooked, m_AD_CheckAndPlayVideo, m_Ad_Show0);
}

static void ad_hook_remove(void) {
    if (!g_adHooked) return;
    dk_unhook_all();
    g_adHooked = 0;
    g_ad_mp_slot = NULL;
    L("⑤ noAd: 已移除");
}
