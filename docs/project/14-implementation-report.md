# GLMUsage 用量洞察实施报告

> **口径更正（2026-11-07）**：本文的 Gate 状态（false）与小时粒度解析口径已被真实接口验收推翻——真实响应为日粒度（`granularity=daily`），Gate 已置 true、解析器已改日粒度直映射、§5 的 Gate 解锁前置项已全部执行完毕。现行事实以 `15-independent-review.md` 末节「真实接口验收」为准，本文仅作历史记录。

- 日期：2026-11-06
- 分支：`feature/glm-usage-insights`（worktree `/Users/Chester/Documents/Zcode/Glmusage-worktrees/usage-insights`，基线 `b0a32a8` / `v1.0.23`）
- 状态：实现完成、离线回归全绿；~~每日数据真实接口 Gate 未验证~~（2026-11-07 已验收通过，见上）
- 变更文件：`GlmUsage.swift`（唯一源码改动）；`AGENTS.md` / `docs/DEVELOPMENT.md`（补新预览参数）；`docs/screenshots/`（截图证据，未提交）
- 未执行：commit / push / merge / 发版 / 部署 / LaunchAgent / 真实用卡 / `--once` / 停止运行中的生产实例——均未被授权，也未发生

## 1. 变更总览

维持仓库单文件约定（`build.sh` 注释明确：多文件编译只有 main.swift 允许 top-level，拆文件需改入口名与构建脚本，收益不抵风险），新增逻辑以 enum/类分层：

| 模块 | 职责 |
|---|---|
| `GLMDayBucket` | 单日桶，`tokens=nil` 表示缺失日，与零日严格区分 |
| `GLMDailyUsage` | `productionGateConfirmed` 生产 Gate 常量（当前 `false`）；`parseTimeline`（严格解析 x_time/modelDataList）；`frame`（完整小时网格聚合成 30 个完整自然日桶） |
| `GLMUsageComparison` | 较昨日 / 较前 7 天纯逻辑：持平 / 新增 N / ±x.x% / 数据不足；缺失不当 0 |
| `CredStore.loadAccountEmail` | 头部可选邮箱：仅从现有凭据库 `oauth:bigmodel:user_info` 读 `rawProfile.email`；纯函数 `resolveAccountEmail` 门禁——env 覆盖 / 任何 api-key 候选（含单个、zai 系）/ OAuth token 不可用 / 解析失败 → nil（整行隐藏） |
| `Fetcher.dailyBuckets` | 同一 30 天响应 → 每日桶三分语义：Gate 关（nil,false=正常空态）/ 解析失败（nil,true=保留旧值+待更新）/ 成功 |
| `GLMDailyChartCanvas` | 30 日柱状图：悬停整天宽命中、零日/缺失日可读、离开保留选中、点击选日、键盘 ←/→、a11y；不联网、无定时器 |
| `GLMComparisonStrip` | 单行浅底圆角条 + 中间竖线，约 30pt；数值 12pt 半粗体、中性展示 |
| `GLMDailyUsageSectionView` | 「每日用量」整块：标题行 + 选中行 + 柱图 + 日期刻度 + 比较条；空态「暂不可用/数据不足」；旧值保留期简短「待更新」 |
| `GLMPillBackground` | 头部套餐 badge 与比较条共用的浅底圆角容器 |

界面变化：

1. **头部（PRD §2.1）**：GLM 应用图标 +「GLM 用量」+ 独立套餐 badge（服务端订阅名，badge 上限宽、超长截断、不挤压标题）；第二行仅邮箱可靠可得时显示，无则整行隐藏不占空高。套餐到期仍在冻结区原位。
2. **「Token 用量（服务端统计）」→「用量情况」**（面板与 NSMenu fallback 同步）；周期 / Token / 调用次数列、今日/7/30 天、多周期模型展开、刷新保留全部不动。
3. **新增「每日用量」**（用量情况之下、MCP 之上）：30 完整自然日柱图（今日未走完不进图）、选中日 Token 值、日期刻度、单行比较条；数据只读慢项缓存。
4. 菜单栏双行、footer、BuildInfo、版本检查与原位更新链路、MCP 独立折叠均未动。

## 2. 数据 schema 证据链（只读公开源，未读真实凭据）

1. **官方插件无 schema**：`zai-org/zai-coding-plugins`（GitHub，main）`plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs`（全文 175 行已核对）对 model-usage 响应只做 `JSON.stringify(json.data)` 原样 dump，无字段解析；插件文档亦无响应 schema。
2. **公开实现字段证据**：`steipete/CodexBar`（Apache-2.0）`Sources/CodexBarCore/Resources/Plugins/zai.js` 的 `modelUsage(daysBack)`：响应 `data` 含 `x_time`（时间标签字符串数组）与 `modelDataList[]`（每模型 `{modelName, tokensUsage[]}` 与 x_time 按下标对齐），据此画小时/日序列；`docs/zai.md` 亦提 "Hourly and daily model token totals"。
3. **邮箱来源证据**：本机 ZCode 客户端 `/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs` 登录流（只读代码，未读凭据）：bigmodel 分支写入 `oauth:bigmodel:user_info = JSON.stringify({id, username, displayName, rawProfile: R.user})`，且 `username = R.user.name || R.user.email || R.user.user_id`（可能回退 user_id，不可靠）；客户端直接引用过的可靠邮箱字段是 `rawProfile.email`，故只信它。

## 3. 解析与聚合的保守规则（fixture 全覆盖）

- **格式不猜**：标签必须满足 `yyyy-MM-dd HH:mm:ss`（本地时区）且 **round-trip 反向格式化后与原文全等**——实测 ICU 对分隔符/补零宽松（`2026/11/05` 能被 `yyyy-MM-dd` 解析），round-trip 才能挡住。
- **整段拒绝**：x_time 缺失/非数组/空、modelDataList 缺失/空/非数组、单条标签不可解析、时间重复或乱序、tokensUsage 长度不齐、null/负值/布尔/非有限值、模型名重复（双计风险）、求和溢出 → 整个序列拒绝，绝不把未知当 0。
- **完整日口径**：某自然日的点必须恰好凑齐当天全部整点小时网格（wall-clock 逐步 +1h 生成期望网格；DST 春令 23h / 秋令 25h 自然正确；`calendar.range(of:.hour,in:.day)` 只回答小时值域 0..<24，不可用于天长——已实测并绕开）。缺 1 小时 / 只有 1 点 / 间隔非 1 小时 / 不整点 → 该日缺失。
- **窗口边界**：今天（未走完）不进图；请求窗口起点当日只覆盖部分小时 → 整日按缺失。现有 `now-30d` 滚动窗下**最老一格恒为缺口，最多 29 个完整日**——按指示不改原周期窗、不加请求凑 30 日，保持 30 格最老缺口。
- **配平**：时间序列求和与 `totalUsage`（周期表数字）**不承诺配平**，来源独立；模型明细列仍只展示 `modelSummaryList`（模型 Token），无输入/输出列、无伪造调用数。

## 4. 已实现的空态与异常语义（PRD §8.3/§9）

| 场景 | 界面 |
|---|---|
| Gate 未确认（生产当前态） | 「暂不可用」+ 两项「数据不足」，无假柱、无补零、无技术脚注 |
| Gate 开启后解析失败/请求失败 | 保留旧图，仅「近 30 天」旁简短「待更新」；无技术错误行 |
| 缺失日选中/悬停 | 「数据不足」（与视觉一致，a11y 同文案） |
| 零值日 | 基线短柱，值显示 `0 Token`，可命中 |
| 比较口径 | D=最新完整日：D vs D−1；截至 D 的 7 完整日 vs 再前 7 完整日（14 日全覆盖才比较）；双方 0=持平；基期 0=「新增 N」；任一缺失=「数据不足」；保留一位小数、中性展示 |

## 5. 真实接口 Gate：未验证（功能未标完成）

`GLMDailyUsage.productionGateConfirmed = false`：生产界面每日区恒显示空态，响应可解析也不会自动激活；`--preview-*` 用合成 fixture 展示目标体验，不代表接口已验证。

**Gate 解锁前置（待主会话安排只读联网验收后执行）**：
1. 用 `--once` 或等效只读核对一次真实 30 天 model-usage 响应，确认：`x_time` 存在、为本地时区小时粒度、整点对齐、时间单调、覆盖请求窗口、`modelDataList[].tokensUsage` 对齐且无空缺（dense 网格假设成立）；若真实响应是稀疏（仅活跃小时）网格，需先重新评审「零日 vs 缺失」口径再激活。
2. 将脱敏真实响应样本固化为 fixture；
3. 把 `productionGateConfirmed` 改为 `true` 并重跑全部回归。

同时未验证：`oauth:bigmodel:user_info` 实际存储形态（enc 与否）与 `rawProfile.email` 字段真实存在性——解析失败即隐藏，风险仅为「邮箱行不显示」，无泄漏风险；邮箱绝不写 status.json/日志（`status.json` 输出未改动）。

**邮箱账号门禁（保守口径）**：任何 api-key 候选（按 `loadApiKey` 同口径：`api-key`+`coding-plan`+`enc:v1:`，含 zai 系与单候选）都直接隐藏——候选归属与 user_info（最后一次 OAuth 登录写入）无法证明同一账号；仅当 `loadApiKey` 实际走纯 bigmodel OAuth 回退且 `access_token` 可用时才展示 `rawProfile.email`（username 为 name→email→user_id 回退链不可信，顶层 email 无 schema 证据，均不采信）。整条决策抽为纯函数 `CredStore.resolveAccountEmail`，self-test 直接覆盖集成路径：env 覆盖 / 单候选 / 多候选 / 无有效 OAuth / username 回退 / 顶层 email（均隐藏）、纯 OAuth 回退 + rawProfile.email（允许，含大小写与空白归一）。

## 6. 冻结区证明

与基线 `/tmp/glmusage-review-baseline.bwPZTy/GlmUsage.swift`（= b0a32a8）逐字节比对：

- `func quota(...)` 额度窗口块（18 行）：**IDENTICAL**
- `resetHeading` → `add(cards)` 重置卡块（48 行）：**IDENTICAL**
- 峰谷卡 `peakCard`（7 行）：**IDENTICAL**
- footer UI（最近尝试刷新/版本按钮/立即刷新/开机自启/退出，12 行）：**IDENTICAL**
- 全文件 diff 删除行仅 15 行，逐行核对全部属于：fetchModelUsage 管线改造、section 改名、旧头部行（PRD §2.1 放开区）、preview 标志条件、popover-test 步骤适配、高度量化、self-test 结束语——无一属于冻结区。

面板基础设施有两处非冻结区的必要修复（不影响任何冻结 UI）：
- `scroll.scrollerStyle = .overlay`（legacy 滚动条样式下出现/消失引发文档宽度抖动 370↔362，进而 Popover 重新定位漂移）；
- 面板高度量化为偶数点（高度奇偶变化使 AppKit 锚点取整漂移 ±1pt，`--preview-popover-test` 曾抓到）。

## 7. 测试命令与结果（最终一轮全部通过）

```
./build.sh                                                  # PASS（v1.0.23-dirty）
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test          # PASS（新增日桶解析 12+ 类拒绝/聚合/DST/比较/邮箱校验/邮箱门禁矩阵）
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test          # PASS 20/20
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-popover-test        # PASS ×5（最终二进制连续 5 轮）
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-daily-test --preview-daily-gaps   # PASS ×2/3（1 轮被用户真实点击关闭 popover 打断，重跑即过）
python3 -m unittest discover -s tests -p '*_test.py'        # OK（22 tests）
bash -n build.sh scripts/update.sh scripts/release.sh       # PASS
```

GUI 回归稳定性说明：测试进程与用户真实输入共存，真实点击会按生产语义关闭 transient Popover（本轮两处仅测试侧防御：回归模式下 popover 行为改 applicationDefined、local monitor 按 windowNumber 解析合成事件窗口；生产路径语义不变）。`--preview-popover-test` 步进放宽至 0.25s、async-refresh 锚点免检（菜单栏邻居宽度变化会平移锚点，锚点稳定性已由各步与边缘放置检查覆盖），并在遇环境关闭时自动重开继续。注意事项（已写回 AGENTS.md / DEVELOPMENT.md）：两套 GUI 测试背靠背启动会因菜单栏图标注册竞态污染几何断言，必须错开 ≥5s 逐个跑。

### `--preview-popover-test` 步骤适配说明

面板加入每日用量后整体更高，原步骤「三个模型窗全开」会被最大高度截断（截断后展开不再改窗口高）。步骤重排为 0/1 开 → 收 1 → 开 2（每步窗口高仍有真实增减，终态仍为断言所需的 `[0, 2]`）；refresh 步骤前先收起 Token 表腾出余量（footer 在滚动区外，达上限后不再改窗口高）。测试保证（live resize、稳定锚点、滚动位置恢复、控件、关闭/重开状态、左右边缘）全部保留。

### `--preview-daily-test`（新增离线回归）覆盖

真实 `NSEvent` 经 `NSApp.sendEvent` 派发（非 `performClick`）：Tab 沿 key view loop 可达柱图（不点击、不强设焦点）→ 悬停整天宽命中 → 零日/缺失日读取 → 列边缘命中 → 离开保留选中（`NSEvent.enterExitEvent` 合成离开，`mouseEventWithType` 不接受 exit 类型）→ 点击选日 → 键盘 ←/→ → a11y 值非空。悬停断言说明：合成 mouseMoved 不经物理光标跟踪，按 responder chain 派发给 first responder；点击步骤仍走真实 hitTest 路径；生产悬停路径为标准 NSTrackingArea。

## 8. 截图矩阵（`docs/screenshots/`，离线假数据预览）

| 文件 | 场景 | 核验点 |
|---|---|---|
| `normal-336.png` | 336pt 默认（含 badge） | 头部 badge、每日图、比较条、冻结区原样 |
| `narrow-280.png` | 280pt | 无溢出，比较条完整 |
| `long-email-280.png` | 280pt 长套餐名 + 长邮箱 | 仅验证 badge 截断不挤压标题、邮箱中间截断（长模型列表把每日区推到视口外，比较条验证见下两行） |
| `email-336.png` | 邮箱行显示（badge 圆角） | 第二行排版、无挤压 |
| `narrow-basezero.png` | 280pt + 基期 0 | 完整看到每日图与比较条：「新增 2.00M │ -30.8%」 |
| `narrow-insufficient.png` | 280pt + 仅近 5 日 | 完整看到比较条：「较昨日 +100.0% │ 较前 7 天 数据不足」，缺口+选中柱 |
| `daily-gaps.png` | 缺失日 + 零日 | 缺口/基线短柱区分；较前 7 天「数据不足」弱化色 |
| `daily-basezero.png` | 基期 0 | 「新增 2.00M」 |
| `daily-unavailable.png` | Gate 关闭空态 | 「暂不可用」+ 双「数据不足」、无假柱 |
| `updating.png` / `updating-install.png` | 更新进度原位 | 进度行替换按钮、footer 不变 |

## 9. 性能证据（可重复测量，同机同条件）

| 指标 | 基线 b0a32a8 | 本分支 | 方法 |
|---|---|---|---|
| `--self-test` 壁钟 ×5 | 0.03–0.04s | 0.03–0.04s | `/usr/bin/time -p`，含新增 fixture 后持平 |
| `--peak-test` 壁钟 ×3 | 0.00s | 0.00s | 同上 |
| 空闲 preview 15s CPU | 0.30s | 0.38s | `ps -o time=`（差值 ≈ 启动噪声级，稳态均近 0） |
| 空闲 preview RSS | 119,952KB | 123,392KB | `ps -o rss=`（+3.4MB：预览桶与新增视图对象） |

未测项（如实声明）：10s 重建 `rebuildMenu` 与 5min 慢刷新热路径未单独埋点。理论增量：每轮重建多创建每日块 ~15 个小视图对象；`frame` 聚合 O(标签数×模型数)（720×数）仅出现在 5 分钟慢刷新的回调线程；悬停/键盘只改选中下标与两处文本，无分配、无网络。如需精确数字需另行埋点验收。

## 10. 剩余阻塞与建议

1. **每日数据 Gate**：按 §5 流程安排只读联网验收（`--once` 需确认生产实例并发约束），此前每日区在生产保持空态——这是有意行为，不是缺陷。
2. **邮箱行**：真实凭据中 `oauth:bigmodel:user_info` 的形态未验证；解析失败即隐藏。可在 Gate 验收时顺带只读核对一次（不落盘、不输出明文）。
3. **账号切换**：与应用既有行为一致（凭据文件变化后慢刷新周期内数据自动更替），未做账号指纹检测（超出本版范围，PRD §10 只要求不串数据——单账号单凭据源场景满足）。
4. **稀疏网格风险**：若真实响应只含活跃小时，激活后大量「零日」会呈「数据不足」；需以真实样本定口径（可能改为「覆盖范围内缺小时=0」，须另行评审），Gate 常量保证在此之前不会上线错误口径。

## 11. 复现清单（审核用）

```bash
cd /Users/Chester/Documents/Zcode/Glmusage-worktrees/usage-insights
git status --short            # 期望：M GlmUsage.swift + 未跟踪 docs（无提交）
git diff GlmUsage.swift       # 全部源码变更
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test
python3 -m unittest discover -s tests -p '*_test.py'
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-popover-test          # 与下一条错开 ≥5s
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-daily-test --preview-daily-gaps
./GlmUsage.app/Contents/MacOS/GlmUsage --preview                       # 假数据 GUI 预览（336pt）
```
