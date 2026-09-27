
// ───────────────────── il2cpp C API ─────────────────────
typedef void* Il2CppDomain;
typedef void* Il2CppImage;
typedef void* Il2CppClass;
typedef void* Il2CppMethodInfo;
typedef void* Il2CppFieldInfo;
typedef void* Il2CppObject;
typedef void* Il2CppString;

typedef struct {
    Il2CppDomain      (*domain_get)(void);
    void*             (*domain_get_assemblies)(Il2CppDomain, size_t *);
    Il2CppImage       (*assembly_get_image)(void *);
    Il2CppClass*      (*class_from_name)(Il2CppImage, const char *, const char *);
    Il2CppMethodInfo* (*class_get_method_from_name)(Il2CppClass *, const char *, int);
    Il2CppMethodInfo* (*class_get_methods)(Il2CppClass *, void **);
    Il2CppFieldInfo*  (*class_get_field_from_name)(Il2CppClass *, const char *);
    Il2CppFieldInfo*  (*class_get_fields)(Il2CppClass *, void **);
    Il2CppClass*      (*class_get_parent)(Il2CppClass *);
    const char*       (*class_get_name)(Il2CppClass *);
    const char*       (*class_get_namespace)(Il2CppClass *);
    const char*       (*method_get_name)(Il2CppMethodInfo *);
    int               (*method_get_param_count)(Il2CppMethodInfo *);
    const char*       (*field_get_name)(Il2CppFieldInfo *);
    size_t            (*field_get_offset)(Il2CppFieldInfo *);
    void              (*field_get_value)(Il2CppObject *, Il2CppFieldInfo *, void *);
    void              (*field_set_value)(Il2CppObject *, Il2CppFieldInfo *, void *);
    void              (*field_static_get_value)(Il2CppFieldInfo *, void *);
    void              (*field_static_set_value)(Il2CppFieldInfo *, void *);
    Il2CppObject*     (*runtime_invoke)(Il2CppMethodInfo *, void *, void **, void **);
    Il2CppString*     (*string_new)(const char *);
    Il2CppObject*     (*object_new)(Il2CppClass *);
    void*             (*thread_attach)(Il2CppDomain);
    void*             (*thread_current)(void);
    void              (*gc_disable)(void);
    Il2CppClass*      (*object_get_class)(Il2CppObject *);
    int               (*class_is_assignable_from)(Il2CppClass *, Il2CppClass *);
    Il2CppObject*     (*value_box)(Il2CppClass *, void *);
    void              (*class_init)(Il2CppClass *);
    const char*       (*image_get_name)(Il2CppImage);
    size_t            (*image_get_class_count)(Il2CppImage);
    Il2CppClass*      (*image_get_class)(Il2CppImage, size_t);
} dk_il2cpp_t;

static dk_il2cpp_t I;
static BOOL ic_ready = NO;

static BOOL ic_init(void) {
    if (ic_ready) return YES;
    if (!g_unityBase) return NO;
    memset(&I, 0, sizeof(I));
    I.domain_get                  = (void*)dk_sym_find("_il2cpp_domain_get");
    I.domain_get_assemblies       = (void*)dk_sym_find("_il2cpp_domain_get_assemblies");
    I.assembly_get_image          = (void*)dk_sym_find("_il2cpp_assembly_get_image");
    I.class_from_name             = (void*)dk_sym_find("_il2cpp_class_from_name");
    I.class_get_method_from_name  = (void*)dk_sym_find("_il2cpp_class_get_method_from_name");
    I.class_get_methods           = (void*)dk_sym_find("_il2cpp_class_get_methods");
    I.class_get_field_from_name   = (void*)dk_sym_find("_il2cpp_class_get_field_from_name");
    I.class_get_fields            = (void*)dk_sym_find("_il2cpp_class_get_fields");
    I.class_get_parent            = (void*)dk_sym_find("_il2cpp_class_get_parent");
    I.class_get_name              = (void*)dk_sym_find("_il2cpp_class_get_name");
    I.class_get_namespace         = (void*)dk_sym_find("_il2cpp_class_get_namespace");
    I.method_get_name             = (void*)dk_sym_find("_il2cpp_method_get_name");
    I.method_get_param_count      = (void*)dk_sym_find("_il2cpp_method_get_param_count");
    I.field_get_name              = (void*)dk_sym_find("_il2cpp_field_get_name");
    I.field_get_offset            = (void*)dk_sym_find("_il2cpp_field_get_offset");
    I.field_get_value             = (void*)dk_sym_find("_il2cpp_field_get_value");
    I.field_set_value             = (void*)dk_sym_find("_il2cpp_field_set_value");
    I.field_static_get_value      = (void*)dk_sym_find("_il2cpp_field_static_get_value");
    I.field_static_set_value      = (void*)dk_sym_find("_il2cpp_field_static_set_value");
    I.runtime_invoke              = (void*)dk_sym_find("_il2cpp_runtime_invoke");
    I.string_new                  = (void*)dk_sym_find("_il2cpp_string_new");
    I.object_new                  = (void*)dk_sym_find("_il2cpp_object_new");
    I.thread_attach               = (void*)dk_sym_find("_il2cpp_thread_attach");
    I.thread_current              = (void*)dk_sym_find("_il2cpp_thread_current");
    I.gc_disable                  = (void*)dk_sym_find("_il2cpp_gc_disable");
    I.object_get_class            = (void*)dk_sym_find("_il2cpp_object_get_class");
    I.class_is_assignable_from    = (void*)dk_sym_find("_il2cpp_class_is_assignable_from");
    I.value_box                   = (void*)dk_sym_find("_il2cpp_value_box");
    I.class_init                  = (void*)dk_sym_find("_il2cpp_runtime_class_init");
    I.image_get_name              = (void*)dk_sym_find("_il2cpp_image_get_name");
    I.image_get_class_count       = (void*)dk_sym_find("_il2cpp_image_get_class_count");
    I.image_get_class             = (void*)dk_sym_find("_il2cpp_image_get_class");
    int miss = 0;
    struct { const char *n; void *p; } req[] = {
        {"domain_get", I.domain_get}, {"domain_get_assemblies", I.domain_get_assemblies},
        {"assembly_get_image", I.assembly_get_image}, {"class_from_name", I.class_from_name},
        {"class_get_method_from_name", I.class_get_method_from_name},
        {"class_get_field_from_name", I.class_get_field_from_name},
        {"field_get_offset", I.field_get_offset}, {"runtime_invoke", I.runtime_invoke},
        {"object_get_class", I.object_get_class},
    };
    for (size_t i = 0; i < sizeof(req)/sizeof(req[0]); i++) {
        uintptr_t a = (uintptr_t)req[i].p;
        if (!a) { miss++; L("ic: MISSING %s", req[i].n); }
        else if (!dk_ptr_executable(a)) L("ic: OUT-OF-RANGE %s = %p", req[i].n, req[i].p);
    }
    if (miss) { L("ic: %d 必需 API 缺失 → 禁用", miss); return NO; }
    ic_ready = YES;
    L("ic ✓ il2cpp C API 就绪 (domain_get=%p invoke=%p)", I.domain_get, I.runtime_invoke);
    return YES;
}

static void ic_ensure_thread(void) {
    if (!ic_ready || !I.domain_get) return;
    Il2CppDomain dom = I.domain_get();
    if (!dom) return;
    if (I.thread_current && !I.thread_current() && I.thread_attach) I.thread_attach(dom);
}

static Il2CppImage ic_find_image(const char *want) {
    if (!ic_ready) return NULL;
    Il2CppDomain dom = I.domain_get();
    if (!dom) return NULL;
    size_t n = 0;
    void **asms = (void **)I.domain_get_assemblies(dom, &n);
    if (!asms) return NULL;
    for (size_t i = 0; i < n; i++) {
        if (!asms[i]) continue;
        Il2CppImage img = I.assembly_get_image(asms[i]);
        if (!img) continue;
        const char *nm = I.image_get_name ? I.image_get_name(img) : NULL;
        if (nm && !strcmp(nm, want)) return img;
    }
    return NULL;
}

// 方法调用包装: 参数按 il2cpp_runtime_invoke 约定 (值类型传指针, 引用类型传对象)
static Il2CppObject *ic_call(void *mi, void *obj, void **args) {
    if (!mi || !I.runtime_invoke) return NULL;
    void *exc = NULL;
    return I.runtime_invoke(mi, obj, args, &exc);   // exc 忽略(异常时返回 NULL)
}

static int ic_call_i32(void *mi, void *obj, int32_t arg) {
    void *args[1] = { &arg };
    Il2CppObject *r = ic_call(mi, obj, args);
    return r ? *(int32_t *)((uint8_t *)r + 0x10) : 0;   // 装箱 int32 → 值在 +0x10
}

static int64_t ic_call_i64(void *mi, void *obj, int64_t arg) {
    void *args[1] = { &arg };
    Il2CppObject *r = ic_call(mi, obj, args);
    return r ? *(int64_t *)((uint8_t *)r + 0x10) : 0;
}

static float ic_call_f(void *mi, void *obj, float arg) {
    void *args[1] = { &arg };
    Il2CppObject *r = ic_call(mi, obj, args);
    return r ? *(float *)((uint8_t *)r + 0x10) : 0.0f;
}

// List<T> / 数组 布局 (Il2CppArray: [klass 0x00][monitor 0x08][bounds 0x10][max_length 0x18][data 0x20])
// Il2CppArray: [klass 0x00][monitor 0x08][bounds 0x10][max_length 0x18][data 0x20]
static int32_t arr_len(void *arr)  { return arr ? *(int32_t *)((uint8_t *)arr + 0x18) : 0; }
static void    *arr_at(void *arr, int i) {
    if (!arr || i < 0) return NULL;
    return *(void **)((uint8_t *)arr + 0x20 + 8 * i);
}
// List<T>: <_items>@0x10 <_size>@0x18
static void    *list_items(void *lst) { return *(void **)((uint8_t *)lst + 0x10); }
static int32_t  list_size(void *lst)  { return *(int32_t *)((uint8_t *)lst + 0x18); }
static void    *list_at(void *lst, int i) {
    void *items = list_items(lst);
    if (!items) return NULL;
    return *(void **)((uint8_t *)items + 0x20 + 8 * i);
}
