# 模型速度卡（第 8 张可选卡片）Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 新增第 8 张独立可选卡片「模型速度」：按周期（今天/近7天/近30天）展示各模型的 decode 速度（tok/s）与首字延迟（TTFT），数据只读本机 ZCode 库 `~/.zcode/cli/db/db.sqlite`，不新增网络请求与定时器。卡片进入现有「···」显隐/排序设置列表，默认可见、默认排在末尾。

**Architecture:** 平行新增 `GLMModelSpeed` 只读读取器（schema 守卫模式对齐 `GLMStartPlanUsage`：缺表→空态，未知 schema→明确拒绝，绝不静默造 0）；`GLMPanelCardID` 新增 `.speed`（布局默认顺序 = allCases，自动进入设置列表末尾）；卡片视图复用「用量情况」的周期行模式；`GLMOfflineRegression` 用临时 fixture 库先行写失败断言。

**Tech Stack:** Swift、AppKit、SQLite3（只读）、现有 `build.sh` / `--self-test` / preview 回归，无新依赖。

---

## 口径定义（实现必须逐条对齐，不得自行发挥）

- **数据源**：仅本机 `~/.zcode/cli/db/db.sqlite` 的 `model_usage` 表。该表含全部连接的逐次请求（GLM、k3、claude 等），不做 provider 过滤——速度对比本来就要跨模型。时间戳为毫秒。
- **decode 速度**：`1000 × SUM(output_tokens) / SUM(completed_at − first_token_at)`，**按模型分组汇总口径**，不做单请求平均（小请求会拉偏）。分母单位毫秒。
- **decode 有效样本**：`first_token_at IS NOT NULL AND completed_at > first_token_at AND output_tokens > 0 AND cancelled_by_user = 0 AND status != 'running'`。
- **TTFT**：`AVG(time_to_first_token_ms)`，仅统计 `time_to_first_token_ms > 0` 的行；显示为一秒一位小数（如 `2.3s`）。
- **tok/s 显示**：整数（如 `153 tok/s`），不显示小数。
- **模型归一**：仅按小写分组去重，显示名保留首次出现的大小写（对齐 `GLMStartPlanUsage.merging` 的既有约定）。
- **排序**：按窗口内 output_tokens 降序（用量大的在前，对齐「用量情况」明细惯例）。
- **样本警告**：当某模型 `有效样本数 / 请求总数 < 0.5` 时，该行追加次要色 `样本N/M`（如 `样本264/370`）；≥0.5 不显示，不做常驻脚注（对齐「每日用量」无脚注的既有决定）。
- **剔除规则**：取消（`cancelled_by_user=1`）、运行中（`status='running'`）、无首字时间、零输出 token 的行不进任何统计。
- **空态**：库文件不存在、缺 `model_usage` 表、窗口内无有效样本 → 显示「暂无模型速度数据」；查询失败或 schema 不识别 → 明确异常态，不静默置零。
- **口径注释**：在 `GLMModelSpeed` 头部注释记录本节口径与 2026-11-15 实测基线（flashx 153 tok/s/首字2.3s、flash 58/3.9s、k3.1-pro 40/8.7s），供后续核对。

## 已确认范围与不可变边界

- 新卡片 `.speed` 显示名「模型速度」，默认可见、默认顺序末尾（MCP 工具之后），用户可经「···」隐藏/排序，隐藏后不参与数据刷新计算量之外无副作用。
- 只读打开数据库（`SQLITE_OPEN_READONLY` + busy timeout 1s），不写库、不联网、不新增定时器——读取挂在面板既有刷新节奏上。
- 不碰凭据/钥匙串；离线回归与 preview 不读真实库、不联网。
- 首版不做：缓存命中率卡（另立需求）、模型回退率、按天展开速度趋势、会话级速度、SwiftBar/菜单栏实时速度。
- 其他 7 张卡片的布局、数据、交互零改动；`PanelCustomization.swift` 仅因枚举新增 case 被动扩展。
- 不往 `AGENTS.md` 追加本功能细节。
- 执行时以实际符号为准，不机械依赖行号。

## UI 规格

```text
模型速度                       [今天 | 近7天 | 近30天]
──────────────────────────────
glm-5.3-flashx          153 tok/s · 首字2.3s
GLM-5.3-Flash            58 tok/s · 首字3.9s
k3.1-pro                 40 tok/s · 首字8.7s 样本203/519
```

- 周期行复用「用量情况」的样式与交互（单选切换，默认近7天；今天样本过少时行区显示「今日样本不足」空态文案，不算异常）。
- 每行：模型名（主文字）｜`N tok/s · 首字X.Xs`（次要文字，右对齐）；样本警告追加在同一次要文字后。
- 卡片标题行不带刷新按钮，跟随面板全局刷新。

---

### Task 1: `GLMModelSpeed` 读取器 + 失败回归先行

**Files:**
- Modify: `GlmUsage.swift`（`GLMStartPlanUsage` 之后新增 enum；`GLMOfflineRegression.run()` 中 Start Plan 断言之后追加）

**Step 1: 先写失败回归（fixture 库，模式照抄 Start Plan 既有断言）**

用临时目录 fixture sqlite（真实列集：`started_at, model_id, status, cancelled_by_user, output_tokens, first_token_at, completed_at, time_to_first_token_ms`），断言：

1. 两组已知时间/字数的行 → decode tps 精确等于手算值（毫秒→秒换算正确）。
2. `cancelled_by_user=1` 的行不进样本与分母。
3. `first_token_at` 为 NULL 的行只计入请求总数、不计入样本。
4. `completed_at <= first_token_at` 的行被剔除，不产生除零。
5. `GLM-5.3` 与 `glm-5.3` 两行合并为一组，显示名保留先出现者。
6. 全部行无效 → 空快照，不抛错。
7. 缺表 → 空快照；建 `CREATE TABLE model_usage (unrecognized TEXT)` → 抛错（不静默置零）。
8. 周期边界：`started_at` 毫秒与 `calendar.startOfDay` 日界正确。

**Step 2: 实现读取器使回归转绿**

结构对齐 `GLMStartPlanUsage.load`：`open_v2` 只读、busy timeout、`no such table` → 空快照、其他 prepare/step 失败 → `ReadFailure`。返回 `[ModelSpeedRow]`：`model, displayModel, requests, samples, decodeTps: Double?, avgTtftMs: Double?, outputTokens`。

### Task 2: 卡片注册

**Files:**
- Modify: `PanelCustomization.swift`（`GLMPanelCardID` 加 `case speed`，显示名「模型速度」）
- Modify: `GlmUsage.swift`（`buildPanel()` 卡片注册区 + 布局默认顺序）

**Step:** 注册 `.speed` 卡片占位视图与数据装配；确认设置列表自动包含第 8 行、默认顺序末尾、恢复默认包含它。离线回归补断言：`GLMPanelLayout.default.order` 含 `.speed` 且位于末位。

### Task 3: 卡片视图

**Files:**
- Modify: `GlmUsage.swift`（速度卡视图构建，复用周期行控件与明细行样式）

**Step:** 周期行（今天/近7天/近30天，默认近7天，持久化策略对齐「用量情况」现状）；按 UI 规格渲染行；空态与「今日样本不足」文案；preview 回归加速度卡快照断言（fixture 数据注入，不读真实库）。

### Task 4: 全量验证与文档

- `bash build.sh` 通过；`--self-test` 全绿（含新增断言）。
- 真机验收（`@cua-driver-cli`）：面板出现「模型速度」卡，数字与 `sqlite3` 手工查询一致（抽 2 个模型）；隐藏卡片后面板其余部分无布局回归；「···」设置列表 8 行完整可排序。
- `README.md`「能做什么」加一条「模型速度」；「统计口径」补 decode/TTFT/样本三句口径。
- 本文档标记实现完成日期。

## 验收清单

- [ ] 回归断言 8 项全绿，fixture 不触真实库
- [ ] 卡片出现在设置列表，可隐藏/排序/恢复默认，默认末尾可见
- [ ] decode 与 TTFT 数字与手工 SQL 一致（抽样 2 模型）
- [ ] 取消/运行中请求不影响数字；样本比 <0.5 的行显示样本计数
- [ ] 缺库/缺表/空窗口三态文案正确，无静默 0
- [ ] 其他 7 卡零回归；无新网络请求、无新定时器、无凭据触碰
