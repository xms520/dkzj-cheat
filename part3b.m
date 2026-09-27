
// ───────────────────── 扩展 il2cpp API (类型对象/虚调用) ─────────────────────
// 追加到 dk_il2cpp_t 的能力（用独立函数指针，避免改动结构体定义）
typedef void* (*ic_class_get_type_fn)(Il2CppClass *);
typedef void* (*ic_type_get_object_fn)(void *);
typedef void* (*ic_object_new_fn)(Il2CppClass *);
typedef void* (*ic_class_get_static_field_data_fn)(Il2CppClass *);

static ic_class_get_type_fn            p_class_get_type;
static ic_type_get_object_fn           p_type_get_object;
static ic_class_get_static_field_data_fn p_static_field_data;

static void ic_init_ext(void) {
    p_class_get_type      = (ic_class_get_type_fn)dk_sym_find("_il2cpp_class_get_type");
    p_type_get_object     = (ic_type_get_object_fn)dk_sym_find("_il2cpp_type_get_object");
    p_static_field_data   = (ic_class_get_static_field_data_fn)dk_sym_find("_il2cpp_class_get_static_field_data");
    L("ic-ext: class_get_type=%p type_get_object=%p static_field_data=%p",
      p_class_get_type, p_type_get_object, p_static_field_data);
}

// 把 Il2CppClass 转成 System.Type 对象 (FindObjectOfType 需要)
static void *ic_type_of(Il2CppClass *k) {
    if (!k || !p_class_get_type || !p_type_get_object) return NULL;
    void *t = p_class_get_type(k);
    return t ? p_type_get_object(t) : NULL;
}

// ───────────────────── 虚调用: 按【运行时实际类】解析方法 ─────────────────────
// ⚠️ 关键: 基类 MethodInfo 调用虚方法在派生实例上可能不生效 (热更/覆写) →
//    一律用 object_get_class 拿运行时类再查方法, 命中覆写版。
static void *vmi(void *obj, const char *name, int argc) {
    if (!obj || !I.object_get_class || !I.class_get_method_from_name) return NULL;
    Il2CppClass *rc = (Il2CppClass *)I.object_get_class(obj);
    if (!rc) return NULL;
    void *m = I.class_get_method_from_name(rc, name, argc);
    if (m) return m;
    // 沿父链回溯 (最多 8 层)
    Il2CppClass *c = rc;
    for (int i = 0; i < 8 && c; i++) {
        c = I.class_get_parent ? (Il2CppClass *)I.class_get_parent(c) : NULL;
        if (!c) break;
        m = I.class_get_method_from_name(c, name, argc);
        if (m) return m;
    }
    return NULL;
}

static void *vcall(void *obj, const char *name, int argc, void **args) {
    void *m = vmi(obj, name, argc);
    if (!m) return NULL;
    return ic_call(m, obj, args);
}

static BOOL vis_obj(void *obj, const char *name, int argc, void **args) {
    void *m = vmi(obj, name, argc);
    if (!m) return NO;
    Il2CppObject *r = ic_call(m, obj, args);
    if (!r) return NO;
    return *(uint8_t *)((uint8_t *)r + 0x10) ? YES : NO;
}

static int64_t vig_i64(void *obj, const char *name, int argc, void **args) {
    void *m = vmi(obj, name, argc);
    if (!m) return 0;
    Il2CppObject *r = ic_call(m, obj, args);
    return r ? *(int64_t *)((uint8_t *)r + 0x10) : 0;
}

static int32_t vig_i32(void *obj, const char *name, int argc, void **args) {
    void *m = vmi(obj, name, argc);
    if (!m) return 0;
    Il2CppObject *r = ic_call(m, obj, args);
    return r ? *(int32_t *)((uint8_t *)r + 0x10) : 0;
}

// 判断对象是否为某类实例
static BOOL is_inst_of(void *obj, Il2CppClass *k) {
    if (!obj || !k || !I.object_get_class || !I.class_is_assignable_from) return NO;
    Il2CppClass *rc = (Il2CppClass *)I.object_get_class(obj);
    return rc ? (I.class_is_assignable_from(k, rc) ? YES : NO) : NO;
}
