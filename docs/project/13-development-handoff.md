# GLMUsage 用量洞察开发交接

> **已归档（2026-11-08）**：任务已完结，功能已合入 main 并随 v1.0.24–v1.0.27 发布；
> 文中 worktree 路径 `Glmusage-worktrees/` 已删除，本文其余指令仅反映当时会话的约束，不再生效。

用户已在主会话确认方案并要求新建 session 开发，完成后由主会话审核。

## 开发位置

- 本 session 初始项目可能为 `/Users/Chester/Documents/Zcode/Glmusage`，该目录仅供读取设计，不在其中改代码或构建。
- **所有代码修改与构建只在** `/Users/Chester/Documents/Zcode/Glmusage-worktrees/usage-insights`。
- 已创建分支 `feature/glm-usage-insights`，基线 `b0a32a8` / `v1.0.23`。
- 原目录 `main` 有未提交 PRD 和设计图，禁止清理／stash／切分支／覆盖。
- 本任务未授权 git commit/push/merge、发版、部署、修改 LaunchAgent、停止或替换正在运行应用、真实用卡。

## 必读

1. worktree 的 `AGENTS.md`、`docs/DEVELOPMENT.md` 与 `docs/project/` 现行文档。
2. `docs/project/11-usage-insights-prd.md`：**v0.3 最新要求**；主图v0.2但头部以PRD §2.1为准。
3. `docs/design/glmusage-usage-insights-v0.2-comparison-strip.png`：最新单行比较条；不要采用comparison-rows或旧v0.2两列松散布局。
4. `docs/design/glmusage-frozen-sections-reference.png`：三块冻结区，不得改样式／文案／位置／交互。
5. `docs/design/glmusage-header-reference.png`：头部参考（Codex，仅学结构，不抄图标／套餐与邮箱）。

## 必交实现

- 头部：GLM自己的图标＋「GLM 用量」＋独立套餐badge（服务端名）。当前GLM邮箱能可靠确定才显示第二行；否则隐藏。不新增个人信息接口、不用ZCode邮箱代替、不泄露凭据或把邮箱写诊断。无邮箱不占空行。
- **冻结**：额度＋套餐到期、峰谷状态、重置卡三块原样。不得给它们去Emoji、换卡片、移日期、改用卡保护。
- 「Token 用量（服务端统计）」改「用量情况」，列仍周期／Token／调用次数，保留今日/7/30及多周期模型展开、刷新保留。
- 「每日用量」放其下：30日柱图，hover立即日期/值，零日可命中、键盘选择；较昨日/较前7天两项固定显示。
- 比较区用**单行浅底圆角条＋中间竖线**，两半每组标签紧邻数值、整体居中；不采用上下两行，不额外加高。
- MCP保持独立；菜单栏、footer、BuildInfo、版本检查与原位更新链路保留。
- 正常界面无技术脚注、来源说明、截至昨日／归日时区待验证、累计无法证明说明、统计口径入口。
- 无Tibo、无累计占位、无输入/输出列、无harness来源分布，不造指标。

## 每日数据的验证边界

- 现有model-usage已知有窗口总量/调用/modelSummaryList，未证实日桶字段/时区/历史上限。
- 首先只读核对官方公开文档/官方插件及源码，日桶解析用脱敏或合成fixture做严谨测试；禁止猜字段成功就声称真实接口验证通过。
- 当前已有生产GlmUsage PID（启动时18976，须实时查）运行。不得在其他实例并发时运行 `--once`，不得停现有实例来绕过。
- 本次开发不自动授权真实凭据网络验收；如无法以现有授权验证，写明真实接口Gate未验证，不能标完成。可先实现可验证解析/图表/比较和明确空态，向主会话报告阻塞，不能拿未知当0或偷偷新增30个请求。
- 正常10s额度/5min慢项节奏不变，复用慢项；hover不联网。

## 工程与验收

- 新逻辑合理模块化，匹配周边命名／注释风格；拆源码同步构建脚本。Swift禁对同存储两个子字段同时inout。
- 每轮代码变更后 `./build.sh`、`--self-test`、`--peak-test`；脚本测试 `python3 -m unittest tests/script_test.py` 或discover、shell语法检查；真实失败必须报告。
- 只启动离线preview/GUI假数据模式，不启动生产联网GUI；不得操作真实凭据、status.json或已有app。
- 预览截图覆盖正常/280与336pt/长名称/无邮箱/缺日与0/基期0/单行数据不足/更新状态；真实鼠标hit-testing，不只performClick。
- 性能提供可重复的新旧对比；无法测量写明未测，不能编造CPU/电量百分比。
- 最终写 `docs/project/14-implementation-report.md`：变更、所有测试命令与结果、GUI路径、性能证据、未验证项、冻结区diff证明。不要提交。

## 与主会话接续

主会话将审查变更和运行回归，发现问题回派。完成后通过可用会话消息机制通知原会话；若无消息工具，至少完成报告并停止代码写入，原会话会检查报告。
