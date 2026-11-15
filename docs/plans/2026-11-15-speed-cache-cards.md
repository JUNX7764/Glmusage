# 模型速度卡 + 缓存命中卡（第 8/9 张可选卡）Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 新增两张独立可选卡片，共用同一个本机只读读取器，一次 SQL 同时产出两组统计：

1. **「模型速度」卡**：按周期（今天/近7天/近30天）展示各模型 decode 速度（tok/s）与首字延迟（TTFT）。
2. **「缓存命中」卡**：同周期展示整体与各模型的缓存命中率与输入量，解释「同样的事为什么今天费额度、明天省」。

数据只读本机 ZCode 库 `~/.zcode/cli/db/db.sqlite`，不新增网络请求与定时器。两卡均进入现有「···」显隐/排序设置列表，默认可见、按「模型速度 → 缓存命中」排在末尾。

**Architecture:** 新增 `GLMLocalModelStats` 只读读取器（schema 守卫模式对齐 `GLMStartPlanUsage`：缺表→空态，未知 schema→明确拒绝，绝不静默造 0）；`GLMPanelCardID` 新增 `.speed` 与 `.cache`（布局默认顺序 = allCases，自动进设置列表）；两张卡视图复用「用量情况」周期行模式；`GLMOfflineRegression` 用临时 fixture 库先行写失败断言。

**Tech Stack:** Swift、AppKit、SQLite3（只读）、现有 `build.sh` / `--self-test` / preview 回归，无新依赖。

---

## 数据事实（2026-11-15 实测，实现前无需重验，口径注释须引用）

- 表：`model_usage`，每行 = 一次实际请求尝试（重试各占一行）。时间戳**毫秒**。
- 本机近 7 天速度基线（decode 口径）：glm-5.3-flashx **153.2 tok/s**/首字 2.3s、GLM-5.3-Flash **58.1**/3.9s、k3.1-pro **39.7**/8.7s、claude-sonnet-5-5 **130.6**/6.4s。GLM-5.3-Flash 有 2354 请求仅 1712 个有效速度样本（73%）。
- **`input_tokens` 即总输入，已包含缓存部分**：`cache_read_input_tokens ⊆ input_tokens`（13739 行含缓存样本中 `cache_read > input` 反例为 0）；`cache_creation_input_tokens` 本机当前全为 0，实现不得假设恒为 0，按字段语义并入输入侧理解。
- 本机近 7 天缓存基线：GLM-5.3-Flash **96%**（316.3M/328.4M）、k3.1-pro **98%**、glm-5.3-flashx **97%**、claude-sonnet-5-5 **76%**（24.0M/31.8M）、deepseek-flash 13 行中仅 9 行有缓存（个别模型可能整窗无缓存 → 显示 `—` 而非 0%）。
- 命中率分子分母口径与 zcode-tps 插件（github.com/yujuntea/zcode-tps-marketplace）的「输入/命中」一致，可交叉核对。

## 口径定义（实现必须逐条对齐，不得自行发挥）

**通用（两卡共享）：**

- 仅读本机 `model_usage` 表，不做 provider 过滤（速度/缓存对比本来就要跨模型）。
- 剔除行：`cancelled_by_user = 1`、`status = 'running'`。
- 模型归一：按小写分组去重，显示名保留首次出现的大小写（对齐 `GLMStartPlanUsage.merging` 约定）。
- 窗口：`started_at`（毫秒）落在周期内；日界用 `calendar.startOfDay`（对齐 Start Plan 读取器）。
- 读取失败或 schema 不识别 → 明确异常态，不静默置零；缺表/库不存在 → 空态「暂无数据」。

**速度卡：**

- decode 速度 = `1000 × SUM(output_tokens) / SUM(completed_at − first_token_at)`，按模型分组汇总口径，不做单请求平均（小请求拉偏）。分母毫秒。
- 有效速度样本：`first_token_at IS NOT NULL AND completed_at > first_token_at AND output_tokens > 0`，且满足通用剔除规则。
- TTFT = `AVG(time_to_first_token_ms)`，仅统计 `> 0` 的行；显示一位小数秒（`2.3s`）。tok/s 显示整数。
- 排序：按窗口内 output_tokens 降序。
- 样本警告：`有效样本/请求总数 < 0.5` 的行追加次要色 `样本N/M`；≥0.5 不显示，无常驻脚注（对齐「每日用量」无脚注的既有决定）。

**缓存命中卡：**

- 模型命中率 = `SUM(cache_read_input_tokens) / SUM(input_tokens)`（input 为含缓存的总输入）；整体命中率 = 全模型合计比值，置顶「整体」行。
- 命中率显示整数百分比（`96% 命中`）；输入量显示 `输入328M`/`输入2.5M`/`输入864K`（复用现有 token 格式化符号；无现成符号则按 3 位有效数字自适应 K/M）。
- **`—` 规则**：窗口内该模型无任何 `cache_read > 0` 或 `cache_creation > 0` 的行 → 命中率显示 `—`（区分「没有缓存数据」与「0% 命中」），不影响其他行。
- `input_tokens ≤ 0` 的行不进任何分母（除零守卫）。
- 排序：按窗口内 input_tokens 降序（缓存与输入量直接相关）。

## 已确认范围与不可变边界

- 两卡显示名「模型速度」「缓存命中」，默认可见，默认顺序：… → MCP 工具 → 模型速度 → 缓存命中；可经「···」隐藏/排序，恢复默认包含两卡。
- 只读打开（`SQLITE_OPEN_READONLY` + busy timeout 1s），一次查询产出两卡数据；挂在面板既有刷新节奏，不新增定时器/网络请求，不碰凭据/钥匙串。
- 两卡周期选择器相互独立（各自记忆选择），交互样式复用「用量情况」周期行。
- 其他 7 张卡片布局、数据、交互零改动；`PanelCustomization.swift` 仅因枚举新增 case 被动扩展。
- 首版不做：缓存写入量独立展示、按天趋势展开、会话级统计、菜单栏实时速度、模型回退率。
- 离线回归与 preview 不读真实库、不联网、不写生产偏好。
- 不往 `AGENTS.md` 追加本功能细节。执行以实际符号为准，不机械依赖行号。

## UI 规格

```text
模型速度                       [今天 | 近7天 | 近30天]
──────────────────────────────
glm-5.3-flashx          153 tok/s · 首字2.3s
GLM-5.3-Flash            58 tok/s · 首字3.9s
k3.1-pro                 40 tok/s · 首字8.7s 样本203/519

缓存命中                       [今天 | 近7天 | 近30天]
──────────────────────────────
整体                     95% 命中 · 输入494M
GLM-5.3-Flash            96% 命中 · 输入328M
k3.1-pro                 98% 命中 · 输入84M
claude-sonnet-5-5        76% 命中 · 输入32M
deepseek-flash            — 命中 · 输入284K
```

- 行格式：模型名（主文字）｜统计（次要文字，右对齐）。「整体」行在缓存卡置顶。
- 今天样本不足：速度卡显示「今日样本不足」、缓存卡显示「今日暂无数据」，均不算异常。
- 卡片不带独立刷新按钮，跟随面板全局刷新。

---

### Task 1: `GLMLocalModelStats` 读取器 + 失败回归先行

**Files:**
- Modify: `GlmUsage.swift`（`GLMStartPlanUsage` 之后新增 enum；`GLMOfflineRegression.run()` 中 Start Plan 断言之后追加）

**Step 1: 先写失败回归（fixture 库，模式照抄 Start Plan 既有断言）**

临时目录 fixture sqlite，建表须含列：`started_at, model_id, status, cancelled_by_user, output_tokens, first_token_at, completed_at, time_to_first_token_ms, input_tokens, cache_read_input_tokens, cache_creation_input_tokens`。断言：

速度：
1. 已知时间/字数两组行 → decode tps 精确等于手算值（毫秒→秒换算正确）。
2. `cancelled_by_user=1` 行不进样本与分母；`status='running'` 同。
3. `first_token_at` NULL 行只计请求数，不进样本。
4. `completed_at ≤ first_token_at` 行被剔除，不产生除零。
5. `GLM-5.3` 与 `glm-5.3` 合并一组，显示名保留先出现者。

缓存：
6. 加权命中率精确等于手算值（`SUM(cache_read)/SUM(input)`）。
7. `input_tokens=0` 行剔除，不产生除零。
8. 个别模型整窗无缓存 → 该行 `cacheHitRate = nil`；全部模型无缓存 → 整体行也为 nil。
9. 缺 cache 列的 fixture（`CREATE TABLE model_usage (unrecognized TEXT)`）→ 抛错，不静默置零；缺表 → 空快照。

边界：
10. 毫秒时间戳与 `calendar.startOfDay` 日界正确；周期外行不进统计。

**Step 2: 实现读取器使回归转绿**

结构对齐 `GLMStartPlanUsage.load`：`open_v2` 只读、busy timeout 1s、`no such table` → 空快照、其他 prepare/step 失败 → `ReadFailure`。一条 SQL 按 `model_id` 分组产出：`requests, decodeSamples, decodeTps: Double?, avgTtftMs: Double?, inputTokens, cacheReadTokens, cacheHitRate: Double?`。头部注释记录本节数据事实与口径。

### Task 2: 卡片注册

**Files:**
- Modify: `PanelCustomization.swift`（`GLMPanelCardID` 加 `case speed`「模型速度」、`case cache`「缓存命中」）
- Modify: `GlmUsage.swift`（`buildPanel()` 注册两卡 + 布局默认顺序）

**Step:** 注册两卡占位视图与数据装配（同一次读取结果喂两卡）。离线回归补断言：`GLMPanelLayout.default.order` 含 `.speed`、`.cache` 且依次位于末两位；设置列表 9 行完整。

### Task 3: 两卡视图

**Files:**
- Modify: `GlmUsage.swift`（两卡视图构建，复用周期行控件与明细行样式）

**Step:** 各自周期行（今天/近7天/近30天，默认近7天，持久化策略对齐「用量情况」现状）；按 UI 规格渲染；正常/样本不足/异常三态文案；preview 回归加两卡快照断言（fixture 注入，不读真实库）。

### Task 4: 全量验证与文档

- `bash build.sh` 通过；`--self-test` 全绿（含新增断言）。
- 真机验收（`@cua-driver-cli`）：两卡出现在面板，速度与命中率数字各抽 2 个模型与 `sqlite3` 手工查询一致；隐藏/排序/恢复默认后其余卡片无布局回归；设置列表 9 行。
- `README.md`「能做什么」补两条；「统计口径」补 decode/TTFT 与命中率口径各一句（注明 input 含缓存）。
- 本文档标记实现完成日期。

## 验收清单

- [ ] 回归断言 10 项全绿，fixture 不触真实库
- [ ] 两卡出现在设置列表，默认末两位可见，可隐藏/排序/恢复默认
- [ ] 速度与命中率数字与手工 SQL 一致（各抽 2 模型）
- [ ] 取消/运行中请求不影响数字；样本比 <0.5 行显示样本计数
- [ ] 无缓存模型显示 `—` 非 0%；缺库/缺表/空窗口三态正确，无静默 0
- [ ] 其他 7 卡零回归；无新网络请求、无新定时器、无凭据触碰
