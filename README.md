# 弹壳战机 1.1.7 全功能 dylib (DKZJ v3.0)

**目标包**: `com.survivor.acecn` (1.1.7, Unity 2022.3.62f2 IL2CPP + HybridCLR 热更)

## 功能 (7 项)
| # | 功能 | 实现路线 |
|---|------|----------|
| ① | 怪物自杀/秒杀 | `EntityManager.EnemyCommitSuicide(entity,reason)`；兜底 `EntityCharacter.SetHp(0)` + `OnDeath(tdd)` |
| ② | 无敌 | `EntityCharacter.AddAbsoluteInvincibility()` + `set_CurrentHp(999999999)` + `AddCharacterStatus(ImmuneDamage)` |
| ③ | 一键通关 | `BattleManager.OnMissionClear()` + `OnChapterEnd()`（先清场） |
| ④ | 游戏加速 | `GameManager.SetTimeScale(f)` / `Game.SetTimeScale(f)` + `WorldContext.gameSpeed`(Q16.16) 直写 |
| ⑤ | 免广告 | MethodInfo.methodPointer 热替换 `ADModuleMgr.CheckAndPlayVideo` → 直接 Invoke 发奖回调 |
| ⑥ | 局内经验 | `BattleData.AddUserExp(n)` + `BattleManager.AddExpAndGold()` |
| ⑦ | 局内金币 | `BattleData.AddDropGold(n)` / `AddWaveGold(n)` |

## 调用链（全部运行时反射，无硬编码偏移依赖）
```
BattleGame.get_World() → WorldBattle
  → get_LogicWorld() → BattleLogicWorld.<_worldContext>
    → BattleWorldContext.{get_Entity, get_BattleMgr, get_BattleData}
```

## 技术要点
- il2cpp 符号双路解析：`dlsym(RTLD_DEFAULT)` + LC_SYMTAB nlist 内存扫描（`__LINKEDIT` vmaddr-fileoff 换算）
- 后台线程 `il2cpp_thread_attach` 解析（HybridCLR 热更类），主线程 tick 消费
- **零 `__TEXT` patch**：仅改数据段函数指针（MethodInfo.methodPointer）
- SIGSEGV/SIGBUS 守卫（嵌套深度安全）包裹全部反射调用
- UI：58pt 悬浮球直接挂游戏 window 顶层 + 卡片面板（球外区域天然不挡触摸）
- 调用链全走 `runtime_invoke` + 虚方法按运行时类解析（避免热更覆写不生效）

## 日志
`Documents/dkzj3.log`；禁用开关文件 `Documents/dkzj3_off`

## 构建
GitHub Actions（macos-14 + iPhoneOS SDK）→ 产物 artifact `DKZJ.dylib`

## ⚠️ 风险提示
- 帧同步游戏：**仅单机 PvE**，联机模式会上行命令到服务器 → 封号风险
- 字段偏移（`_worldContext` / `gameSpeed` / `_curTimeScale`）来自 metadata v31 静态分析，
  运行时若命中失败会自动降级到方法调用路线；日志中若出现 `off=0x0` 说明该路失效
- 枚举 `CharacterStatusType.ImmuneDamage = 2` 为【推测，需真机验证】（v31 枚举值解析存在字节偏移）
