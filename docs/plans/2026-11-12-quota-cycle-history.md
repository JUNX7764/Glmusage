# GLM 周额度周期回顾 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在每日用量卡与 MCP 工具卡之间新增原生「额度周期回顾」，按实际观测到的 7 天额度轮次回看使用比例、积分余额和重置原因，不伪造历史或账号归属。

**Architecture:** 新增 Foundation 纯模型/状态机、按套餐连接隔离的版本化本地仓库、串行协调器与 AppKit 图表模块；`GlmUsage.swift` 只负责现有凭据上下文、额度刷新、用卡证据与面板接线。只消费已有请求的有效周额度响应，不新增网络请求，不从 Token 或本地请求数据库反推积分，也不继续向主文件堆积周期算法。

**Tech Stack:** Swift / Foundation / CryptoKit / AppKit / Darwin，macOS 13+、Apple Silicon，现有 `build.sh` 与 `GLMOfflineRegression`，Python unittest 编译独立 Swift 夹具，Cua 原生 UI 验收。

---

## 0. 状态、执行入口与权限

- **本文是待执行计划，不表示功能已实现、构建已通过或真实接口已验收。**
- 基线：`d23ce84`（`Align panel cards with translucent backgrounds`），2026-11-12 对照源码核验。实施前再次检查 HEAD 与工作区，符号锚点优先于本文行号。
- 专用 worktree：`/Users/Chester/.proma/agent-workspaces/glmusage/2697bd2e-0b15-4ceb-b771-148976e9c17b/plan-worktree`。
- 分支：`plan/glm-quota-cycle-history-20261112`。
- 原 checkout 的 `AGENTS.md` 有用户/运行时已有未提交改动；本计划不复制覆盖、不提交该改动，也不在计划阶段维护项目地图或长期记忆。
- 本轮只编写计划，不构建、不安装、不重启用户运行中的 App、不读取真实凭据、不联网验收、不消费重置卡、不提交或发布。
- `superpowers:*` 是模板名称；实际执行使用已提供的 `@executing-plans`，不安装或声称存在未提供的子技能。
- 以下 commit 均为**未来实施检查点**。用户未允许提交时保留检查点而不运行；只暂存列出的任务文件，不添加任何工具归因。
- 所有命令从上述 worktree 执行。绑定工作区后仍核对 `pwd`；不要误在原 checkout 运行构建或编辑。
- 每个 Step 是一次可验证动作；测试矩阵逐例加入，不把一整个 Task 当成一次大修改。发现失败先确认失败原因，再做最小实现。

## 1. 产品决策与 Codex 方案的差异

参考来源：`/Users/Chester/.proma/agent-workspaces/codexusage/897728c0-8b1e-4e6e-a188-f03c0d2cb73d/plan-worktree/docs/plans/2026-11-12-quota-cycle-history.md`。复用其观测证据、窄面板交互与分层测试思路，不直接复制接口、身份假设或构建配置。

### 1.1 本计划默认范围

1. 首版**仅记录 7 天额度**，不加入 5 小时/7 天切换。模型保留明确的窗口类型，避免混用卡。
2. 卡片顺序：用量进度 → 峰谷状态 → 重置卡 → 用量情况 → 每日用量卡 → **额度周期回顾** → MCP 工具。当前没有 Codex 的 Tibo 卡；不硬套它的卡片数量或名称。
3. 每屏 6 轮，默认最新一页，当前轮次位于最右；初始可浏览最近 12 轮，「更早记录」每次放开另外 12 轮。12 是浏览范围，不是存储上限。
4. 每轮两柱：中性灰为额度上限 100%，主题绿为已用比例。浅色绿 `#3E8660`、深色绿 `#96CDA7`，复用 `GLMPeakTint.accent`，不复制 Codex 暖橙，也不把余量告警色当作历史柱主色。
5. 图表纵轴统一百分比；详情显示本轮**实际接口积分**，如「已用 72% · 剩余 2,800 / 10,000 积分」。不把积分叫 Token，不硬编码 Lite/Pro 上限，不跨轮相加成“总浪费”。
6. 主要结束标签是「正常到期」「主动用周卡」；额外保留「额度窗口变化（原因未确认）」「观测缺口」「额度规格变化」。**不设置“官方被动重置”标签，也不把未知变化自动归因于用卡。**
7. 卡片独立折叠，默认展开；选中详情两行、固定区域。悬停临时查看，点击固定，移出恢复固定选择；左右键逐轮并可跨页。关闭重开、刷新保留本进程选择和历史页，重启回最新页，连接切换清空 UI 选择。
8. 常规面板宽度为 **340pt**，窄预览 **280pt**，不是 Codex 的 330pt。展开总高度目标 200pt、上限 220pt，详情可用 tooltip/VoiceOver 提供完整原文，不能缩小现有全局字号或加宽面板。
9. 没有真实历史时显示「从首次成功读取周额度后开始记录」，不从每日 Token 图补造过去的额度轮次。

### 1.2 账号归属的实施决策（必须先接受，不留到 UI 阶段猜）

当前代码没有已验证的套餐 account ID；邮箱只作展示，不能证明手动 API Key 与 ZCode 双 token 属于同一账号。为保证首版可实施，本计划采用**套餐连接分区，不冒充账号分区**：

- 明确来源为 API Key（环境变量、已保存套餐 Key、ZCode 的 API Key 候选）时，对实际发请求的 Key 在内存做域隔离 SHA-256：`SHA256("glm-quota-cycle-v1|open.bigmodel.cn|api-key|" + key)`。只保存 64 位 hex 分区标识，不保存 Key。相同 Key 可续接，换 Key 新开分区，绝不因同邮箱自动合并。
- OAuth 回退来源仅作**本进程临时记录**，不将易轮换的 access token 指纹当稳定账号落盘。提示「当前登录方式仅保留本次运行记录」。未来有经过验证的稳定身份后另做迁移，不在本功能增加身份接口。
- 对 API Key 模式，ZCode 用卡操作与当前套餐身份不能被证实时，即使本机点卡成功，也**不能**把当前周轮次标为「主动用周卡」。只能记录未归属的本机操作提示；额度自行出现已确认窗口变化时仍标原因未确认。
- 只有监控额度确实使用同一 ZCode `maas` OAuth token（内存精确相等）且操作前后连接未切换时，才允许将该周卡操作绑定当前临时历史。该相等性由现有读取结果证明，不用邮箱、文件同源、时间接近或 JWT 未验证声明替代。归属性是操作时的内存证据，不能仅因磁盘元数据里有一个旧 `attribution=true` 就在新进程恢复为已证明。
- 详情说明「历史按套餐连接保存；更换 Key 不自动合并」。本地 hash 是隐私相关标识，不写诊断日志或对外上传；本地目录权限受限。
- 这比 Codex 的稳定 `account:` 方案更保守；**不得复制其账户接口，或假装 GLM 已具备稳定 account identity。**

### 1.3 用卡协议与安全不变项

- GLM 成功仍为 `code==0 && data.used==true`，保留 `ResetUseOutcome(used,error,retryable)`；不引入 Codex 的 `reset / already_redeemed / nothing_to_reset` 服务端枚举。
- 7 天图只关联 `ResetCardType.week`；5 小时卡不结束周轮次。
- 用卡只能用户点击并二次确认；未知结果保留原幂等 key，历史功能不重试、不新增消费请求。
- 必须保留原操作 `createdAt` 与操作 hash。相同 key 的未知→成功核对只是一笔操作，不在核对时刻再生成一轮。
- 成功响应先记录事实，等后续有效周额度确认再拆段；消费前发出的额度请求不能充当消费后样本。保持当前立即刷新和成功后 3 秒补刷，不额外添加定时请求。
- 既有 pending 文件按卡类型存储且没有身份；旧条目只可作为“原操作时间已知、归属未知”处理，不能补造账号或当前基线。不得为了记录历史删除旧幂等 key 或换新 key。若实施发现必须改变跨账号重试协议才能继续，停止该改动并说明，不顺手重写消费功能。

## 2. 当前代码地图与接入位置

| 文件 / 符号（基线附近行号） | 已核对事实 / 实施动作 |
|---|---|
| `GlmUsage.swift:135–232` / `CredStore.loadPlanCredential`、`resolvePlanCredential`、`loadResetCredential` | 凭据优先 env → saved Key → ZCode API Key → OAuth。增加纯来源上下文，旧 tuple API 保持兼容，不扩大凭据读取权限。 |
| `GlmUsage.swift:233–285` / 邮箱解析 | 已明确 API Key 与 ZCode 邮箱不可证明同账号；历史不得拿邮箱分区或归因。 |
| `GlmUsage.swift:360` / `LimitEntry` | 已有 `limit/used/remaining/usedRatio/reset`，比例基于余额推导。保存真实 credits，不只存百分比。 |
| `GlmUsage.swift:670–720` / `ResetCardType`、`ResetUseOutcome`、`GLMPendingResetStore` | 原 pending 有 key/createdAt，按 FIVE_HOUR/WEEK 存；不重复发明 Codex 响应分类。 |
| `GlmUsage.swift:1013–1125` / `Fetcher.parseQuota` | CREDIT_LIMIT: unit=6 为周，`number` 实测是 1，不得要求 7；nextResetTime 是 epoch 毫秒；used 允许超过 limit。 |
| `GlmUsage.swift:1210–1327` / reset 请求和解析 | 使用 ZCode 双 token，成功码 0；用卡证据必须从此现有结果接入。 |
| `GlmUsage.swift:2066` / `GLMPanelCard` | 当前内容水平内边距14pt、圆角12pt、外侧16pt、卡间距8pt；保留材质与背景主题，不能照搬Codex卡内8pt。 |
| `GlmUsage.swift:2137` / `GLMPeakTint` | 新图调用主题绿动态色，灰柱用动态中性色。 |
| `GlmUsage.swift:2290–2630` / 日图相关 NSView | 参考整列命中、键盘与 VoiceOver，不把日图改造成周期图。 |
| `GlmUsage.swift:2670–2748` / pending、supportDir、planCredential | 当前只用凭据 hash 拒绝旧响应，无历史连接代际。新增专用 generation，不改变真实凭据保存协议。 |
| `GlmUsage.swift:2874–2934` / `refresh`、`performQuotaRefresh`、`finishQuota`、`applyQuota` | **额度独立通道才是正确采样入口**；不要照抄 Codex 的 `performRefresh/applyQuota` 签名。历史读本次 fresh.week，不读合并后旧 usage.week。 |
| `GlmUsage.swift:2936–3118` / `performRefresh`、`finishRefresh` | 慢通道抓模型/卡/套餐，不是周额度采样来源；不能据卡数量减少推断用卡。 |
| `GlmUsage.swift:3394–3461` / `beginUseReset` | 用户确认、幂等 key、未知结果保留、立即刷新、成功 3 秒补刷，均保持。 |
| `GlmUsage.swift:3587–3945` / `buildPanel` 内卡片组装 | 340/280pt，dailyCard 与 mcpCard 之间插入新卡，更新显式 key view loop。 |
| `GlmUsage.swift:3302` / `rebuildPanel`、`3199` / `renderBar` | 历史快照回调只重建面板，不调会写 status.json 的 renderBar/updateUI，防止写入循环。 |
| `GlmUsage.swift:4091–4415` / 预览交互 | 已有 Popover 定位和每日图事件回归，新增周期测试不能放宽旧断言。 |
| `GlmUsage.swift:4845–5724` / `GLMOfflineRegression` 与 CLI | 现有自检入口在 top-level；多文件编译需临时 main.swift，纯历史 runner 不编译整个主文件。 |
| `build.sh` | 当前只编译一个 arm64 源文件、最低 macOS 13、SDK 26+、优先 local-codesign；不引入 universal 任务或改签名策略。 |
| `tests/script_test.py` | 现有 PATH mock 回归；不能替代图表 UI 证据。 |
| `docs/DEVELOPMENT.md`、`docs/project/02-architecture.md` | 存在已滞后的单文件/签名/v2 重置卡描述；实施后按实际代码修正相关句子，不把旧文档当事实。 |

## 3. 数据语义、状态机与不确定性

### 3.1 什么算一轮

- “7 天”是接口窗口类别，不是自然周，也不保证被展示的观测段完整持续七天。
- 首样本只有 `expectedResetAt` 和 `firstObservedAt`；**不默认将 resetAt−7天 当成真实开始**。尤其周卡可能改余额但不改到期时刻。首轮显示「首次观测 11/12 · 开始时间未知」。
- 已观测转换才有边界区间 `[最后旧样本.observedAt, 第一新样本.observedAt]`。用卡的操作区间可收窄证据，但不要把 HTTP 响应时刻伪装成服务端准确重置时刻。
- 旧 reset 已过、接口仍返回旧窗口时为「等待窗口更新」，不能仅凭机器时钟造新轮次。
- 超过连续观测阈值且窗口变化：只封存旧观测段为 gap、新开一个实际观察到的段；不猜漏了几周，不画缺失零柱。
- 图底日期表达观测/边界的精度；首次未知以 `11/12*` 配图例说明，不把 firstObservedAt 叫真实额度开始日期。

### 3.2 积分与比例

```swift
struct GLMQuotaObservation: Codable, Equatable {
    let requestStartedAt: Date
    let observedAt: Date
    let limitCredits: Double
    let reportedUsedCredits: Double
    let remainingCredits: Double
    let resetAt: Date
    let planLevel: String?

    var usedPercent: Double {
        100 * (limitCredits - remainingCredits) / limitCredits
    }
    var isValid: Bool {
        let dates = [requestStartedAt, observedAt, resetAt]
        return dates.allSatisfy { $0.timeIntervalSince1970.isFinite }
            && requestStartedAt <= observedAt
            && resetAt.timeIntervalSince1970 > 0
            && limitCredits.isFinite && limitCredits > 0
            && reportedUsedCredits.isFinite && reportedUsedCredits >= 0
            && remainingCredits.isFinite && (0...limitCredits).contains(remainingCredits)
    }
}
```

- 与现有额度条一致，用 `(limit−remaining)/limit` 计算占用比例，不重复使用服务端已取整 percentage，也不从 Token 推算积分。
- reportedUsedCredits 保留原始服务端读数，可超过 limit；不将超额样本直接扔掉。余额与 currentValue 的一致性警告由现有解析提供，历史 adapter 拒收带周额度 warning 的样本，面板当前额度条保持原有行为。
- 非有限值、负数、余额超上限、无 reset、周窗口失败不进入历史。5 小时成功不能替代周成功。
- 不命名 `finalUsed/wastedCredits`，而命名 `lastObservedUsedPercent/remainingAtLastObservation`。
- 正在进行的可信新鲜样本可显示「当前剩余」；闭合轮次显示「最后观测剩余」，附最后成功时间。正常到期可补「到期前最后观测」，**不输出确定“实际到期未用 X 积分”**。
- 失联到期、gap、规格变化、待确认时不称浪费。不把用卡前剩余计入到期未用。
- 图上 99.6% 四舍五入成 100% 不能算已用满；只在接口 remainingCredits==0 时标「已用满（观测余额为 0）」，保留接口取整局限。
- limit 或已确认非空 planLevel 变化，单独标「额度规格变化」，不解释为用卡或正常浪费。仅 planLevel 从 nil 补全不拆段。
- 峰谷折扣已反映在接口扣分中，不再对积分二次乘 0.5，也不把 Start Plan 赠送 Token 加到套餐积分。

### 3.3 注入参数（本地保守策略，不是 GLM 协议保证）

```swift
struct GLMQuotaCyclePolicy {
    // GLM 返回绝对毫秒时间，不继承 Codex reset_after_seconds 的 120 秒容差。
    var resetJitter: TimeInterval = 2
    var meaningfulDropPP: Double = 1
    var confirmationMinDelay: TimeInterval = 10
    var confirmationMaxDelay: TimeInterval = 180
    var maximumContinuousGap: TimeInterval = 15 * 60
    var heartbeatInterval: TimeInterval = 5 * 60
}
```

所有时间由样本和注入 clock 提供；纯模型测试不 sleep。不将每 10 秒请求写成每 10 秒落盘。

### 3.4 状态转移表

| 前后证据 | 行为 |
|---|---|
| 同 reset、分母相同、用量不减 | 更新本轮；完全重复不增长证据数组。 |
| reset 漂移 ≤2s | 视作同轮，ID 稳定；保留原始读数，不累计漂移偷换轮次。 |
| 同 reset、余额明显回升 | 候选“额度回修／重置待确认”，保留旧可信读数与新证据；没有绑定用卡证据不能据下降独断新轮。 |
| reset 变化但用量未下降、旧截止未到 | 时间调整候选，不立刻拆段，不猜官方重置。 |
| 旧截止前 reset 明显向后、比例下降≥1pp | 第一笔候选，10–180s 内下一独立请求确认同新窗口后拆段，原因 unknownChange（不是官方被动重置）。 |
| 候选回旧窗口 / 同请求重放 / 超时 | 回滚或保持待确认，不凭旧候选补一个已结束轮次。超时后新候选必须重新取得独立确认。 |
| 正常跨旧截止、reset 向后，间隔≤15min | 两笔新窗口独立采样确认 natural；允许 0→0；边界保留区间。 |
| 两笔间隔>15min、窗口变化 | 优先 gap，不因新 reset 刚好是旧 reset+7天 就宣称完整自然轮换。 |
| 绑定的 week 操作 used=true | 记录 operationHash、原 createdAt、响应时刻、基线 ID；等消费后新样本证实新窗口/余额回升后拆 redeemed。 |
| 绑定 week 操作但 reset 相同 | 若两笔消费后独立样本都支持较旧基线下降，可拆 redeemed；0→0 且 reset 不变则只记操作，不造可见的新轮。 |
| API Key 模式的 ZCode 卡成功 | 记“本机用卡，套餐归属未确认”，不标 redeemed。随后发生窗口变化按 unknownChange 判定。 |
| fiveHour 操作成功 | 不影响周轮次、周候选或已确认结束原因。 |
| unknown / 明确失败 | 不造已确认边界；unknown 只保留原事件与原 key，历史代码不能调用消费接口。 |
| 用卡重试确认成功 | 同 operationHash 去重；不在重试现在补一条“现在用卡”。缺少原基线或归属证据只留未归属操作。 |
| 分母/已知套餐级别变化 | 单独规格变化段，保留旧段，不计到期未用；需要稳定样本确认。 |
| 无效、旧连接、旧 epoch、乱序、警告样本 | 拒收，不推进历史成功时间，不用缓存旧值制造心跳。 |
| 本机时间回拨 | 不凭时间倒序造新轮，提示记录待恢复；不能用 Date 字符串排序弥补。 |

优先级：无效/过期拒收 → 连接和 epoch → 规格变化 → gap → 可绑定用卡 → 自然到期 → 原因未知变化 → 同轮。每个分类都必须对应测试，不能用一个“reset 变了”分支包打天下。

## 4. 模块、接口与持久化契约

### 4.1 新文件与职责

- `Sources/GLMQuotaCycleHistory.swift`：值类型、状态机、证据压缩、详情格式与浏览模型，Foundation-only。
- `Sources/GLMQuotaCycleContext.swift`：CryptoKit 分区、连接模式、来源与用卡可归属性纯函数；不访问真实钥匙串、文件或网络。
- `Sources/GLMQuotaCycleStore.swift`：JSON schema 校验、私有目录/文件、小型原子 writer；不读取 auth。
- `Sources/GLMQuotaCycleCoordinator.swift`：串行 load/reduce/save、激活代际、快照回调。
- `Sources/GLMQuotaCycleHistoryView.swift`：AppKit 图表、分页、详情、辅助功能；不读磁盘或凭据。
- `tests/quota_cycle_history_test.py`：编译一次 runner、按 case 执行。
- `tests/fixtures/quota-cycle-history/main.swift`：固定 epoch、假凭据、临时目录，禁止读取真实 HOME 凭据。
- `docs/project/17-quota-cycle-history.md`：实施后当前规格与存储说明。
- `docs/verification/<实际验收日期>-quota-cycle-history.md`：区分模型、磁盘、原生预览与真实长期采样证据。
- `CHANGELOG.md`：先检查是否已存在，再新增或更新实际 Unreleased 条目，不补造旧历史。

建议值类型：

```swift
enum GLMQuotaCycleEnd: String, Codable {
    case natural, redeemed, unknownChange, gap, specificationChanged
}
enum GLMQuotaCycleStart: String, Codable {
    case firstObserved, observedTransition, redeemed, afterGap, specificationChanged
}
enum GLMQuotaOperationResult: String, Codable {
    case requested, confirmedUsed, unknown, rejected
}
struct GLMQuotaOperationEvidence: Codable, Equatable {
    let operationHash: String
    let originalRequestedAt: Date
    let responseAt: Date?
    let isWeek: Bool
    let result: GLMQuotaOperationResult
    let baselineCycleID: UUID?
    let attributionProven: Bool
}
```

`GLMQuotaCycleRecord` 保存 UUID、startKind、first/lastObservedAt、expectedResetAt、limitCredits、最后可信 Observation、边界上下界、end、incomplete、压缩证据。pending 保存第一笔候选、旧轮次 ID、原因、首请求时间；全局状态保存 schemaVersion=1、closed/current、pending、操作哈希表与最后接收请求时间。分区路径由协调器掌管，JSON 不含原始 identity。

```swift
struct GLMQuotaCycleReducer {
    init(policy: GLMQuotaCyclePolicy)
    func ingest(_ sample: GLMQuotaObservation, into state: inout GLMQuotaCycleState)
    func record(_ evidence: GLMQuotaOperationEvidence, into state: inout GLMQuotaCycleState)
}

final class GLMQuotaCycleStore {
    typealias Writer = (Data, URL) throws -> Void
    init(root: URL, writer: @escaping Writer)
    func load(partition: String) throws -> GLMQuotaCycleState
    func save(_ state: GLMQuotaCycleState, partition: String) throws
}

final class GLMQuotaCycleCoordinator {
    // Token 只有非敏感的 partition/session ID、activation 与 epoch，不含 Key/token。
    init(root: URL, writer: @escaping GLMQuotaCycleStore.Writer,
         deliver: @escaping (GLMQuotaCycleSnapshot) -> Void)
    func activate(_ context: GLMQuotaHistoryContext)
    func observe(_ sample: GLMQuotaObservation, token: GLMQuotaCaptureToken)
    func record(_ evidence: GLMQuotaOperationEvidence, token: GLMQuotaCaptureToken)
}
```

以上是实施契约，不能把未实现空壳当作生产功能交付。

### 4.2 磁盘约定

- 路径：`~/Library/Application Support/GlmUsage/quota-history/<64hex>/history-v1.json`。
- 路径仅接受小写 64hex；目录 0700、文件 0600；不存 Key/token/邮箱、原始响应、原幂等 key、卡 ID 或完整请求。
- 当前工程没有 Codex 的 `AtomicJSONFile`；**不能引用不存在的工具类**。在 Store 内实现小型 writer：同目录独占创建 0600 临时文件 → 写完关闭 → 原子 rename 替换；失败清理本次临时文件、不删旧文件。目录权限在写前限制，不修改用户全局 Application Support 权限。
- writer 依赖注入以测试写盘失败。load 不存在返回空态；损坏/未知 schema 保留原文件，本进程只读恢复为临时记录并显示原因，禁止下次刷新把坏文件覆盖掉。
- 解码验证所有嵌套日期、数值、唯一 ID、候选引用、操作 hash 和序列约束，不只检查顶层 schema。
- 写失败后保留最后成功文件、内存继续记录；UI「历史未保存」，以后写成功可清除。损坏/未来版本保护与普通写失败重试是不同状态，不能用同一布尔解除保护。
- 首次、额度语义变化、候选/边界/操作变化立即保存；纯时间推进最多 5min 心跳。重复等值样本只更新末端，不每次追加 evidence。
- 已关闭轮次不按 12 条裁剪。首版整份紧凑 JSON 加载，内存分页展示，不宣传为磁盘惰性分页；测试至少 1,000 轮的 round-trip/浏览边界。有实际性能问题才另提分年归档，不引入数据库。
- preview 与所有 fixture 使用明确注入的内存/临时根；不先初始化真实 Store 再 guard。历史路径不加入 status.json。

### 4.3 并发与刷新 gate

- 发额度请求前捕获 context、activation、quotaEpoch、requestStartedAt；回调接受时仍核对既有 `planCredentialMatches` 与 savedConnection，再核对历史 token。
- 连接切换时 activation++、清旧历史 UI、激活目标分区；A→B→A 的第一次 A 请求不得重新合法。
- 周卡确认且需要隔离消费前样本时 quotaEpoch++；记录事实后再接受新的 quota 请求。不会因同连接 epoch 变动重读旧磁盘或清空历史。
- 串行队列按捕获时上下文保存已确认操作，旧连接事实可留在旧分区，不能覆盖新连接 UI。队列交付到主线程前再次核对 activation。
- 历史异步回调只更新 snapshot 并 `rebuildPanel()`，不调用 `updateUI()`、`renderBar()` 或 `refresh()`。
- 尚在加载旧磁盘时先排队新样本，不能用“先收到的网络样本”覆盖加载出来的历史，也不能把旧磁盘快照回调覆盖新内存状态。

## Task 1：建立纯模型测试骨架与第一笔观测

**Files:**
- Create: `Sources/GLMQuotaCycleHistory.swift`
- Create: `tests/quota_cycle_history_test.py`
- Create: `tests/fixtures/quota-cycle-history/main.swift`

**Step 1: 写首个失败测试与 runner。** Python 初始文件如下（后续添加模块路径与 case 方法）：

```python
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class QuotaCycleHistoryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.binary = Path(cls.tmp.name) / "quota-history-tests"
        subprocess.run([
            "swiftc", str(ROOT / "Sources/GLMQuotaCycleHistory.swift"),
            str(ROOT / "tests/fixtures/quota-cycle-history/main.swift"),
            "-o", str(cls.binary),
        ], cwd=ROOT, check=True, timeout=120)

    def case(self, name):
        result = subprocess.run([str(self.binary), name], cwd=ROOT,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: " + name, result.stdout)

    def test_first_observation(self):
        self.case("firstObservation")
```

Swift runner 起点：

```swift
import Foundation
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let t = Date(timeIntervalSince1970: 1_800_000_000)
func sample(_ seconds: Double, _ remaining: Double, _ reset: Double = 604800,
            _ limit: Double = 10000) -> GLMQuotaObservation {
    GLMQuotaObservation(requestStartedAt: t.addingTimeInterval(seconds - 1),
        observedAt: t.addingTimeInterval(seconds), limitCredits: limit,
        reportedUsedCredits: limit - remaining, remainingCredits: remaining,
        resetAt: t.addingTimeInterval(reset), planLevel: "PRO")
}
switch CommandLine.arguments.dropFirst().first {
case "firstObservation":
    var state = GLMQuotaCycleState()
    let reducer = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    reducer.ingest(sample(0, 5700), into: &state)
    check(state.closed.isEmpty, "must not fabricate old rounds")
    check(state.current?.startKind == .firstObserved, "start is unknown")
    check(state.current?.lastObservation.remainingCredits == 5700, "keep credits")
    check(state.current?.lastObservation.usedPercent == 43, "derive percentage")
    print("PASS: firstObservation")
default:
    fputs("FAIL: unknown test case\n", stderr); exit(1)
}
```

**Step 2: 运行确认失败。**

```bash
python3 -m unittest discover -s tests -p 'quota_cycle_history_test.py' -v
```

预期源文件/类型不存在而 FAIL，不是凭据、网络或 GUI 错误。

**Step 3: 最小实现。** 按 §3.2 值类型实现校验；添加 State/Record 与 reducer 的首观测分支，只创建 current，不造起点或 closed。

**Step 4: 重跑测试。** 预期 `test_first_observation ... ok`；检查进程没有启动 App、没有读用户凭据。

**Step 5: 检查点。**

```bash
git add Sources/GLMQuotaCycleHistory.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: model observed GLM weekly quota history"
```

## Task 2：同轮更新、积分有效性与取整边界

**Files:** Modify 上述模型与两个测试文件。

**Step 1: 每次加入一个失败 case。** `sameWindow`（余额5700→5600，ID不变）、`duplicate`、`resetJitter`（±1/2s与超过2s）、`invalidObservation`（NaN/Inf/负余额/超余额/无效日期）、`reportedOverage`（reportedUsed>limit仍合法）、`roundingNotFull`（余额40/10000=99.6%非用满）、`outOfOrder`（同请求重放与旧 requestStartedAt）。

**Step 2: 每加一例运行单 case。** 用 Python 方法名如：

```bash
python3 -m unittest discover -s tests -p 'quota_cycle_history_test.py' -k same_window -v
```

预期新增断言 FAIL；若 `Ran 0 tests` 不是有效证据，修正方法名/命令。

**Step 3: 最小实现同轮逻辑。** 原始余额下降/回升都不取 max 隐藏；候选未实现前回升保留待处理证据，不覆盖旧可信样本。记录最后接收请求，重复样本不当第二请求。

**Step 4: 跑全部历史 unittest。** 预期所有已加 case PASS、closed仍为空，credits与比例一致。

**Step 5: 检查点。**

```bash
git add Sources/GLMQuotaCycleHistory.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: validate GLM credit observations and stable cycle updates"
```

## Task 3：自然轮换、原因未知变化与缺口状态机

**Files:** Modify `Sources/GLMQuotaCycleHistory.swift` 和两个历史测试文件。

**Step 1: 写转换失败 case。** 起点样本余额2800、旧reset=t+604800；在 t+100 余额9800、新reset=t+605800，第一笔只能 pending；t+120 余额9700且新reset相同才封存一段，旧段末值仍2800，end为unknownChange。另外为自然截止构造 t+604790旧样本、t+604810/604830新窗口，避免被15min gap规则误分。

**Step 2: 单独运行新 case。** `earlyUnknownConfirmed`、`naturalZeroToZero` 预期 FAIL，且不是日期单位错误（夹具统一 epoch 秒）。

**Step 3: 实现 §3.4 对应分支。** pending保存首新样本和旧ID；确认必须不同请求且10–180s；边界封存在首新样本之前。恢复后仍按相同证据规则确认。

**Step 4: 逐项加入并跑矩阵。** `candidateRollback`、`candidateTimeout`、`replayNotConfirmation`、`sameResetDropUnconfirmed`、`resetMovesWithoutDrop`、`pastResetWaiting`、`gapAcrossThreeWeeks`、`limitChanged`、`planLevelEnriched`、`clockBackwards`。要求缺口只创建一条新观测段、不补三条零记录；分母变化不计作自然到期；未知与官方重置标签不可混淆。

**Step 5: 检查点。**

```bash
git add Sources/GLMQuotaCycleHistory.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: conservatively classify GLM quota transitions and observation gaps"
```

## Task 4：连接上下文、分区与可归属性

**Files:**
- Create: `Sources/GLMQuotaCycleContext.swift`
- Modify: `tests/quota_cycle_history_test.py`（编译源增加 Context）
- Modify: `tests/fixtures/quota-cycle-history/main.swift`

**Step 1: 写纯函数失败测试。** 固定假 key `fixture-plan-a/b`；同 Key 不同读取来源分区相同、不同 Key 不同分区、结果严格64hex。OAuth模式无磁盘partition；同邮箱不能合并。只有 active OAuth 与操作maas精确相等才true，API Key即使字符串碰巧相同但来源声明为API Key也不能true。

**Step 2: 跑测试确认 Context 缺失而失败。** 与 Task 1 同命令。

**Step 3: 实现 Context 与 gate 的纯函数。** 以枚举区分 `.apiKey` / `.oauth`，纯函数只接收调用方已取得的参数，不自行读 CredStore。提供非敏感 CaptureToken（session/partition标识、activation、epoch、requestStartedAt）。SHA-256 操作使用 CryptoKit，不写到 status.json。

**Step 4: 添加 A→B→A 与失效 gate 测试。** 相同 Key 但旧 activation 拒收；用卡后旧 epoch拒收；凭据不可用立即撤下历史，不使用旧邮箱或旧额度来猜分区。预期全部 PASS。

**Step 5: 检查点。**

```bash
git add Sources/GLMQuotaCycleContext.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: isolate GLM quota history by verified credential context"
```

## Task 5：GLM 用卡证据去重与窗口类型

**Files:** Modify `Sources/GLMQuotaCycleHistory.swift`、Context及两个历史测试文件。

**Step 1: 写失败用例。** 同操作hash按 requested→unknown→confirmedUsed 重放两次；要求只一笔操作。fiveHour不拆周；attributionProven=false不标redeemed；同reset但已确认绑定周卡且余额2800→10000→9900可确认一次；0→0同reset只记操作。

**Step 2: 跑新增 case 确认失败。** 不调用 Fetcher，不使用真实卡。

**Step 3: 实现 `record` 与 reducer 关联。** 绑定旧基线、原createdAt与responseAt；消费后样本要求 requestStartedAt≥确认responseAt。历史状态对已确认操作单调合并，不允许迟到unknown回调将confirmedUsed降级；历史算法不产生网络动作。

**Step 4: 补重启/旧事件/基线缺失测试。** 原操作发生于旧轮，延迟确认不能重置当前新轮；基线ID不匹配只留提示；旧pending缺归属不补造；明确失败不拆轮；尚未见额度改变只显示操作，不造新柱。全部历史用例 PASS。

**Step 5: 检查点。**

```bash
git add Sources/GLMQuotaCycleHistory.swift Sources/GLMQuotaCycleContext.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: correlate only attributable GLM weekly reset evidence"
```

## Task 6：私有分区仓库、损坏保护与写入压缩

**Files:**
- Create: `Sources/GLMQuotaCycleStore.swift`
- Modify: 两个历史测试文件（runner编译源增加 Store）

**Step 1: 写 roundTrip / invalidPartition / writeFailure 的失败用例。** 每次 Swift case 自建并 defer清理临时目录，writer闭包可throw；断言旧文件字节不变。禁止以真实supportDir运行。

**Step 2: 跑新增测试确认 Store 未实现而失败。**

**Step 3: 实现 Store 和小型原子 writer。** 可采用下列写入骨架，生产封装需定义自己的错误类型并把POSIX错误转可读错误：

```swift
import Foundation
import Darwin
func writePrivateJSON(_ data: Data, to destination: URL) throws {
    let fm = FileManager.default
    let dir = destination.deletingLastPathComponent()
    try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                           attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    let tmp = dir.appendingPathComponent(".history-\(UUID().uuidString).tmp")
    let fd = Darwin.open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close(); try? fm.removeItem(at: tmp) }
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    guard Darwin.rename(tmp.path, destination.path) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
```

还须设置本功能`quota-history`根目录为0700、校验partition和JSON数值/引用；不修改更外层用户目录权限。只操作自己的固定路径，拒绝分区/目标为符号链接，避免越界。空文件、损坏和未来schema与“不存在”分别返回。

**Step 4: 逐项测试保护和去重。** 目录0700/文件0600、路径穿越与symlink拒绝、nestedNaN/重复UUID/坏候选引用拒绝、futureSchema保留文件、损坏后后续save被保护、pending恢复、同值10秒观测不增长evidence、5min心跳仅替换末端、候选回滚证据保留、1,000轮round-trip。预期全部PASS，writer次数精确断言。

**Step 5: 检查点。**

```bash
git add Sources/GLMQuotaCycleStore.swift Sources/GLMQuotaCycleHistory.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: persist private GLM quota history without overwriting unknown data"
```

## Task 7：串行协调器与跨连接迟到回调

**Files:**
- Create: `Sources/GLMQuotaCycleCoordinator.swift`
- Modify: 两个历史测试文件（增加编译源）

**Step 1: 写失败测试。** 用注入writer/回调队列与semaphore或expectation控制顺序：load未结束前到新观测；A切B后A的迟到load；A旧操作已确认后切B；同连接epoch递增。不得靠sleep碰运气。

**Step 2: 跑新增case，确认缺少协调器而失败。**

**Step 3: 实现串行load→reduce→save。** 激活token与UI交付二次核对；旧分区可保存既有事实但不覆盖当前UI；新epoch不重读磁盘。OAuth临时模式从不调用Store，快照包含loading/volatile/unsaved/protected信息。

**Step 4: 测试恢复与输出循环。** 写失败→后续成功清unsaved；future schema保护不清除；同值快照不重复交付；回调不触发刷新。预期历史unittest全部PASS。

**Step 5: 检查点。**

```bash
git add Sources/GLMQuotaCycleCoordinator.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: coordinate GLM history activation and ordered persistence"
```

## Task 8：稳定浏览模型与两行详情语义

**Files:** Modify `Sources/GLMQuotaCycleHistory.swift` 和两个历史测试文件。

**Step 1: 写分页/详情失败测试。** 0/1/5/6/7/12/13/25/1000轮；25轮最新为19..<25、上一页13..<19；13轮经“更早记录”能看到最旧一轮。natural详情必须有“最后观测”，gap不能含确定“到期未用”，首次起点未知明确，credits分母按每轮保存值。

**Step 2: 跑新case确认失败。**

**Step 3: 实现浏览状态。** selectedCycleID与pageAnchorID，而不是长期数组下标；loadedLimit初始12、loadEarlier每次+12、页大小6。可使用以下边界函数作为无锚点时的范围计算：

```swift
func visibleRange(total: Int, olderPage: Int, pageSize: Int = 6) -> Range<Int> {
    let count = max(0, total), size = max(1, pageSize)
    let maxPage = max(0, (count - 1) / size)
    let page = min(max(0, olderPage), maxPage)
    let upper = max(0, count - page * size)
    return max(0, upper - size)..<upper
}
```

新增轮次时优先按锚点ID保持旧页；不能只套此索引函数使历史页整体滑动。详情用formatter纯函数，日期显示观测精度，VoiceOver包含完整时间。

**Step 4: 测试刷新保持。** 最新页可跟随最新；历史页刷新不跳；键盘跨页选中同一ID；失效ID选择最近仍存在条目；连接切换才重置。预期全PASS。

**Step 5: 检查点。**

```bash
git add Sources/GLMQuotaCycleHistory.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: add stable cycle paging and honest GLM credit details"
```

## Task 9：接入 GLM 额度独立通道与来源上下文

**Files:**
- Modify: `GlmUsage.swift` / CredStore纯解析、AppDelegate属性、bindPlanCredential、performQuotaRefresh、finishQuota、applyQuota、GLMOfflineRegression
- Modify: `build.sh`

**Step 1: 写离线adapter测试。** 从入口小函数测试fresh.week=nil但usage.week存在不采样；fresh.fiveHour成功不能代替；weekWarning拒收；旧activation/epoch拒收；连接切换清旧历史；不会读真实auth。CredStore新增来源元数据的纯resolver使用假record覆盖env/saved/API候选/OAuth顺序。

**Step 2: 将非UI模块列入构建并确认测试失败。** 主文件仍有top-level，先改构建为临时main.swift，而不是删除入口或把全文件复制进Sources：

```bash
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
cp "$DIR/GlmUsage.swift" "$BUILD_DIR/main.swift"
swiftc -O -target arm64-apple-macos13.0 -o "$DIR/GlmUsage-bin" \
  "$BUILD_DIR/main.swift" \
  "$DIR/Sources/GLMQuotaCycleHistory.swift" \
  "$DIR/Sources/GLMQuotaCycleContext.swift" \
  "$DIR/Sources/GLMQuotaCycleStore.swift" \
  "$DIR/Sources/GLMQuotaCycleCoordinator.swift"
```

保留原sdk门槛/Info.plist/打包/local-codesign逻辑；新增trap必须兼容已有清理（基线无trap，实施时复查）。构建/self-test中新增断言应先FAIL。

**Step 3: 最小接线。** CredStore提供内部typed上下文，旧loadPlanCredential tuple包装继续可用；发请求前只读取一次当前上下文并捕获开始时间。保留原planCredentialMatches/savedConnection gate。接收本次合法week后将Observation交给协调器，再按旧GLMFreshness合并UI。不得拿合并后usage.week入账。切换连接立即清空历史snapshot与选择；preview构造直接使用fixture，不构造生产Store。

特别修正启动隔离位置：基线 `applicationDidFinishLaunching` 在preview分支之前无条件读取生产pending文件；应把该读取放入 `!preview` 分支（或为fixture显式注入临时pending源），不能仅新增Store guard后就宣称预览完全隔离。不要为source元数据读取主动解锁钥匙串。

**Step 4: 跑构建和回归。**

```bash
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test
python3 -m unittest discover -s tests -p '*_test.py' -v
bash -n build.sh scripts/update.sh scripts/release.sh
```

预期新旧测试PASS；不运行--once。self-test仍使用临时根，历史回调不调用renderBar写status.json。

**Step 5: 检查点。**

```bash
git add GlmUsage.swift build.sh
git commit -m "feat: capture GLM weekly history from accepted quota responses"
```

## Task 10：接入原生用卡操作，不改消费协议

**Files:** Modify `GlmUsage.swift` / beginUseReset、GLMPendingResetStore（仅必要的可选历史元数据）、GLMOfflineRegression；Modify 历史测试文件（adapter断言）。

**Step 1: 写离线用卡接线失败断言。** 假操作依次喂入现有ResetUseOutcome；只有used=true确认；原createdAt/hash跨重试不变；成功只生成证据、不生成额度；fiveHour不触发周epoch。测试不能真实实例化会联网的AppDelegate来“假装离线”。

**Step 2: 跑self-test确认新断言失败。** 不更改parseResetUseResponse来满足Codex枚举。

**Step 3: 最小接线。** 用户确认后捕获当前连接、基线ID和是否真正同OAuth身份；以原key的hash记录requested，响应映射confirmedUsed/unknown/rejected。确认周卡后隔离消费前样本；原立即刷新和3秒补刷保留。跨连接回调保留原操作的事实，但不更新新连接历史；历史故障不能妨碍保留原幂等key。

对旧pending：已有createdAt继续使用，新增字段如baselineCycleID/attribution只为可选值。没有字段不推断为当前轮；不删除旧pending，不为“归属不明”生成新key，不把token/hash身份塞进历史JSON。不得顺便改7天pending retention；跨账号重试若需要协议级改动另行提出。

**Step 4: 跑全部离线回归。** 与Task 9同组命令；加断言请求数没有因历史增加、unknown不自动重试、UI二次确认/preview禁用均保持。没有使用真实卡。

**Step 5: 检查点。**

```bash
git add GlmUsage.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: attach safe GLM redemption evidence without extra consumption"
```

## Task 11：340/280pt 原生双柱卡片与假数据预览

**Files:**
- Create: `Sources/GLMQuotaCycleHistoryView.swift`
- Modify: `build.sh`（显式增加UI源）
- Modify: `GlmUsage.swift` / buildPanel、preview数据入口、布局断言

**Step 1: 写几何与内容失败断言。** 13轮固定fixture含natural/full、natural/余额1900、redeemed、unknownChange、gap、规格变化、current、pending与写盘失败；要求daily→history→MCP顺序，六组×两柱无越界，详情两行固定区域，零值与缺失不同。对340/280两宽度都测，不能先在宽网页设计后直接当原生验收。

**Step 2: 构建预览，确认新卡缺失导致失败。** 此时允许FAIL，不把只找到文字当作布局通过。

**Step 3: 实现section/view。** 新视图接收snapshot、browser state和主题绿；主文件用现有GLMPanelCard包装。不要跨文件调用private内部helper；必要theme通过参数注入，不为新图扩大整套UI工具访问权限。

```text
额度周期回顾                          折叠
上限 / 已用                     ‹ 最近6轮 ›
[最多6组：灰色100%柱 + 主题绿已用柱]
[精简日期；首次观测*；当前组低透明度底]
11/06–11/10（约） · 主动用周卡
最后观测剩余 28% · 2,800/10,000 积分
```

常规内容宽按实际GLMPanelCard.contentInset计算：340−32−28=280pt，窄版280−32−28=220pt；不能复制Codex的282pt常量或8pt卡内边距。图约96pt含日期；必要轴区约20pt；六列均分剩余空间，两柱各约6–7pt、间距约3pt；窄模式动态压缩列间空白，不缩小全局文字。上限只统一标100%，各柱不重复塞长标签。缺失/未知用斜线或占位，不画成0；pending显示中性虚线/提示，仍保留最后可信柱。卡片不足6轮高度稳定。

**Step 4: 跑预览几何并检查截图。** 新参数只在实现后可运行：`--preview --preview-quota-history`；暗色加现有`--preview-dark`，窄版加`--preview-narrow`；空态/一轮/13轮/未保存/临时模式由`--preview-quota-history-state=<empty|short|long|unsaved|volatile|protected>`固定选择。flag只在preview gate内生效，单独传历史flag不得启用假数据或改变生产记录。目标200pt，超过220pt或280宽溢出需修布局，不暗中扩面板。

**Step 5: 检查点。**

```bash
git add Sources/GLMQuotaCycleHistoryView.swift GlmUsage.swift build.sh
git commit -m "feat: render native green GLM quota cycle history card"
```

## Task 12：悬停、分页、键盘、折叠与刷新稳定性

**Files:** Modify `Sources/GLMQuotaCycleHistoryView.swift`、`GlmUsage.swift` / UI状态和preview事件入口、历史fixture。

**Step 1: 写事件失败断言。** 整列含柱间空白悬停、点击固定、移出恢复、左右键跨页、更早记录、折叠重开、后台快照重建保留selectedID、连接切换清旧详情。通过真实事件派发或Cua，不直接调用handler冒充点击。

**Step 2: 运行新增专用测试入口确认FAIL。** 待新增：

```bash
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-popover --preview-quota-history --preview-quota-history-test
```

测试fixture固定epoch，结果输出PASS/FAIL与单独sidecar（如`/tmp/glm_quota_history_test_result.txt`，每次先清理本测试旧结果）；拿不到key window应明确“未完成键盘验收”并非伪PASS。该入口必须列入preview识别、previewPopover判定、自动打开调度和仅测试的applicationDefined行为分支，不能只是定义flag却没有执行事件测试；绝不读凭据或生产history。

**Step 3: 实现交互与key view loop。** UI state由AppDelegate独立属性或独立state对象持有，不藏在每次重建就丢失的新view里。显式连接用量情况→daily（若展开）→history（若展开）→MCP；新图不能跳过或截断已有Tab链。VoiceOver每组提供日期精度、结束原因、已用%、余额/分母、最后观测时刻。

**Step 4: 回归原交互。** 刷新不关面板，Esc/外点关闭、滚动位置、原日图、工具卡、模型行、Popover窗口身份/顶部锚点均保持；展开折叠历史不重置连接或触发网络。以下命令逐个运行、等待进程结束后间隔≥5s，解锁屏幕验证键盘，预期新旧断言PASS：

```bash
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-popover-test
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-daily-test --preview-daily-gaps
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-update-test
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-popover --preview-quota-history --preview-quota-history-test
```

最后一条仅测试时使用applicationDefined；Esc/外点关闭须另在普通transient预览里用Cua验证，不用测试行为替代生产交互。

**Step 5: 检查点。**

```bash
git add Sources/GLMQuotaCycleHistoryView.swift GlmUsage.swift tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: preserve accessible GLM history navigation across refreshes"
```

## Task 13：完整离线回归、原生验收与证据报告

**Files:** Create after verification `docs/verification/<实际日期>-quota-cycle-history.md`；修复代码若有问题回原Task补测试，不藏进报告提交。

**Step 1: 执行完整离线回归。**

```bash
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test
python3 -m unittest discover -s tests -p '*_test.py' -v
bash -n build.sh scripts/update.sh scripts/release.sh
lipo -archs GlmUsage.app/Contents/MacOS/GlmUsage
codesign --verify --deep --strict GlmUsage.app
```

预期测试PASS、shell语法检查无输出、架构arm64、签名verify成功。**不要求x86_64/universal，也不为本功能改签名身份。**

**Step 2: 执行隔离原生预览矩阵。** 所有参数须在Task 11/12实现后运行，每个进程结束后≥5s再启动下一个：

```bash
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-quota-history
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-dark --preview-quota-history
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-narrow --preview-quota-history
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-quota-history --preview-quota-history-state=empty
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-popover --preview-quota-history --preview-quota-history-test
```

补short/long/unsaved/volatile/protected、当前候选、跨年、系统不同时区、纯色/毛玻璃/液态玻璃（系统支持时）。未知flag或立即退出不算通过；每个预览读取退出状态/sidecar与实际窗口。截图输出在会话工作台，不把草图写仓库。

**Step 3: 使用 `@cua-driver-cli` 验证真实 AppKit。** 先list_windows、展示ComputerUsePreview，再点六列、固定选择、移出、前后翻页、更早记录、键盘跨页、折叠重开、滚到MCP。复核340与280、浅深色可读性。假数据原生预览仅证明原生布局/交互，不等于真实账号跨周验收；不得用浏览器HTML替代。测试完成结束Cua session/preview，只退出本次创建的preview进程，不杀用户生产App。

**Step 4: 写证据报告。** 报告列出实际执行命令、日期/HEAD、各case计数、原生截图路径及观察结论、失败/未验证项。临时目录模拟save→退出→load、连接A/B切换、损坏/未来schema、不可写writer，检查fixture没有写真实history或读auth。首次实现不跑--once、不真实用卡；长期真实数据与消费协议线上行为如未验证必须写明。

**Step 5: 检查点。**

```bash
# 日期替换为实际完成验收日，不直接复制占位符。
git add docs/verification/YYYY-MM-DD-quota-cycle-history.md
git commit -m "test: document GLM quota history verification and limitations"
```

## Task 14：当前文档、CHANGELOG 与交付

**Files:**
- Create: `docs/project/17-quota-cycle-history.md`
- Create or Modify: `CHANGELOG.md`
- Modify: `README.md`
- Modify: `docs/DEVELOPMENT.md`
- Modify: `docs/project/02-architecture.md`
- Modify: `docs/project/07-standards.md`
- Modify: `AGENTS.md`（仅实际改变的全局模块/命令，计划阶段不执行）

**Step 1: 写文档检查清单。** 必须能找到：7天首版、卡片位置、6/12浏览、真实credits与百分比区别、历史从首次成功采样开始、未知起点/最后观测、未归属卡不强行标主动、API Key分区与OAuth临时模式、更换Key不合并、磁盘格式/目录/保护策略、预览测试与未验证范围。

**Step 2: 对照实现核验。** 与本计划出现差异时记录执行偏差，不能把设计目标写成已验收事实。核对已有文档滞后的v2解密/重置卡支持、稳定签名与单文件描述，仅在实际源码和本轮证据足够时修正相应句子；不重写无关发布历史。

**Step 3: 写文档与CHANGELOG。** README面向用户只留使用方式与局限，17号主题保留完整状态机与分区语义，DEVELOPMENT新增源文件/预览/测试命令。CHANGELOG详细记录新功能、证据限制、连接隔离、故障保护；不擅自更改版本号。AGENTS仅补全局模块入口与必要命令，具体SOP在主题文档，不追加长细节。

**Step 4: 最终核验。**

```bash
git diff --check
git status --short
git diff --stat
```

不得包含生产history JSON、auth、原Key/token、操作原key、图片草稿或编译缓存。不修改其他checkout的AGENTS；若实施期间有项目地图瘦身提醒，按当时Coach reference在可写实施阶段下沉维护，不能在本计划阶段伪记周检完成。

**Step 5: 检查点与交付。**

```bash
git add README.md CHANGELOG.md docs/DEVELOPMENT.md docs/project/02-architecture.md docs/project/07-standards.md docs/project/17-quota-cycle-history.md AGENTS.md
git commit -m "docs: explain GLM quota cycle semantics and safe recording scope"
```

交付功能摘要、离线回归结果、原生验收与长期真实观测未验证边界。合并、部署、真实用卡、对外发布需另外授权。

## 5. 最终验收矩阵

| 编号 | 必须满足 |
|---|---|
| A1 | 每日用量后、MCP前新增一张原生卡；既有峰谷/重置卡/用量卡顺序和材质不变。 |
| A2 | 340/280pt每屏最多6组双柱，统一100%轴，主题绿动态色；图表不扩面板、不挤压旧字号。 |
| A3 | 最近12轮可浏览并扩展更早；不足6轮不伪造；current最新页最右；刷新保持稳定ID。 |
| A4 | 只统计7天轮次；5小时卡不拆周；不存在“官方被动重置已确认”的推断。 |
| A5 | 保存每轮真实分母/余额/原始used，比例与现有余额算法一致；不由Token推积分、不二次计算折扣。 |
| A6 | 无真实起点不减7天造起点；关机跨周不补零；lastObserved不冒充final；99.6不因显示四舍五入标满。 |
| A7 | API Key按连接分区，换Key不合并；OAuth仅本次运行；邮箱与ZCode文件同源不证明套餐归属。 |
| A8 | 不可归属用卡不标主动；原操作hash/时间去重；重试确认不制造现在新轮；不自动消费或额外请求。 |
| A9 | A→B→A、旧epoch、乱序、带warning与失败样本拒收；旧回调不覆盖新连接UI。 |
| A10 | 私有权限、原子写、损坏/未来版本保护、写失败恢复、证据压缩与1000轮测试通过。 |
| A11 | 真正事件验证悬停/固定/翻页/键盘/折叠；原日图与Popover锚点/滚动/关闭交互无退化。 |
| A12 | arm64构建、self-test、peak-test、Python回归、签名通过；原生假数据与真实长期采样证据明确区分。 |

## 6. 风险、停止条件与执行交接

1. **身份不足是实际限制，不是“以后再说”的小细节。** 若要求API Key模式也必须精确标注本机用周卡，应先解决监控Key与双token身份的可验证关联，不能用时间接近冒充；本计划默认降级为原因未确认。
2. **同截止时间的余额回升可能无法区分修正与重置。** 无绑定操作证据就保留待确认，不为图表好看强制拆段；可能漏分但不能谎报。
3. **自然到期前最后余额不是最终浪费。** 所有历史余额可追溯最后成功时刻；不作跨轮总浪费KPI。
4. **原pending消费协议不借机大改。** 若发现跨账号重试安全问题需要新的身份协议，保留既有key、停止相关扩展并提出独立修复；历史读取不能成为换key盲重试的理由。
5. **窄面板六组若不可读，先删重复标签/优化固定详情。** 仍不达标时交用户实测截图决定是否改每页数量，不偷偷改验收或加宽App。
6. **真实网络、授权与部署边界。** 不新增凭据权限、不自动弹钥匙串、不修改ZCode、不跑--once、不真实消费卡、不替换用户App或发布；需要时单独确认。
7. 推荐检查点：Task 1–5（口径与证据）→ Task 6–10（持久化与接线）→ Task 11–12（原生UI）→ Task 13–14（验收与文档）。前一阶段未通过，不堆叠后一阶段大修改。
8. 后续可在本会话按任务执行并检查，或另开会话使用`@executing-plans`、绑定本worktree分批执行。只有独立对抗审查或独立探索才委派；互相依赖的主文件接线任务不并行写同一文件。

## 7. 执行偏差

暂无。实施时按事实补充，不在计划阶段写“已完成”。
