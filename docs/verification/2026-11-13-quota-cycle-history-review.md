# GLM 周额度周期回顾：统筹复核与补充验收

日期：2026-11-13。基于活动 worktree 的 `dc60239` 及本轮未提交修复；分支 `plan/glm-quota-cycle-history-20261112`。此前实现和验收记录已存在，本轮独立对照源码、补失败测试并复跑，不将此前报告代替实际验证。

## 结论

在本次离线与原生假数据验收范围内通过，可进入用户确认后的合并/安装阶段。本轮未提交、合并、安装、重载 LaunchAgent、真实用卡或发布，未运行 `--once`。真实账号跨周采样和真实用卡联动仍未验证。

## 审查与修复

Terra high 子 Agent 完成模型/Store 的定向审查与四文件修复，父会话审核 diff，并负责协调器、主文件、原生视图和最终集成复跑。

| 问题 | 修复与证据 |
|---|---|
| 同窗口余额回升小于 1pp 被静默忽略 | 任意余额回升保留候选，回落保留回滚观测，不修改 1pp 的拆段阈值；新增 `smallReboundPending`，先失败再通过。 |
| 回滚证据晚于最后可信余额，Store 拒绝正常状态 | 活动段按最后接受样本校验、已结束段按边界校验；`rollbackThenSmallReboundStore` 验证保存、重载和后续结束后再次保存。 |
| 缺响应时间或失效基线的用卡证据污染可保存状态 | 缺响应时间的 confirmedUsed 拒收；未知基线降级为不归属操作；`operationInvalidState` 覆盖。 |
| 刷新重建后历史图丢键盘焦点 | 在通用 buildPanel 路径保留并恢复历史图 firstResponder；新增真实事件回归，修复前出现 `FAIL refresh lost history keyboard focus or selection`，修复后通过。 |
| 已结束段详情带上当前轮 pending 提示 | pending 只附加于当前段；同一事件回归断言闭合段辅助功能详情不含当前待确认。 |
| 分页按钮无边界禁用/辅助功能标签 | 最新页禁用「更新」，已加载边界禁用「更早的周期」，全部已加载禁用「加载更早记录」；提供明确语义名称。 |
| 固定选择与悬停、待确认缺少独立视觉标识 | 固定选择保留描边，当前 pending 使用中性虚线；父会话 Cua 实际点列后截图确认。 |
| reset 抖动导致额外写盘，余额不变时详情时间停留首样本 | 语义比较不因已接受同轮 reset 抖动触发写盘；五分钟心跳同步发布 UI 快照，OAuth 临时模式同样更新。新增 self-test：修复前 `FAIL reset jitter alone must not force history writes`，修复后写次数与心跳时间断言通过。 |
| 非预览误用截图参数可能改变面板高度 | full-height 截图条件增加 preview gate；生产不受该参数影响。 |

补充过期额度提示，明确显示的是最后观测余额；CHANGELOG 与当前功能说明同步更新。

## 本轮实际执行结果

| 命令 | 结果 |
|---|---|
| `./build.sh` | 成功；SDK 26+、macOS 13 部署目标、原签名策略不变。 |
| `./GlmUsage.app/Contents/MacOS/GlmUsage --self-test` | PASS，包含新增协调器抖动写频与心跳 UI 时刻断言。 |
| `./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test` | 8/8 PASS。 |
| `python3 -m unittest discover -s tests -p '*_test.py' -v` | **64 tests / 56.836s / OK**，含 30 项历史测试与原脚本回归。 |
| `bash -n build.sh scripts/update.sh scripts/release.sh` | 通过，无输出。 |
| `lipo -archs GlmUsage.app/Contents/MacOS/GlmUsage` | arm64。 |
| `codesign --verify --deep --strict GlmUsage.app` | 通过。 |
| 历史原生事件测试 | PASS：Tab、整列悬停、点击、跨页键盘、刷新后焦点/选择、待确认隔离、边界按钮、加载更早、折叠重开。 |
| `--preview-popover-test` | PASS：原窗口/锚点、缩放、滚动恢复、控件、异步刷新与开合。 |
| `--preview-daily-test --preview-daily-gaps` | PASS：整列命中、零日/缺日、离开保留、点击、键盘、辅助功能与重开。 |
| `--preview --preview-update-test` | PASS：居中卡片、滚动、刷新、取消、预览安装禁用与背景。 |

四组 GUI 进程逐个执行、每个退出后间隔至少 5 秒，并取得 key window。测试全为假数据，不操作生产历史或真实卡。

日志目录：`/Users/Chester/.proma/agent-workspaces/glmusage/2697bd2e-0b15-4ceb-b771-148976e9c17b/review-logs/`。主要文件：`final-build.log`、`final-unittest.log`、`final-gui-history.log`、`final-gui-popover.log`、`final-gui-daily.log`、`final-gui-update.log`；红测试保留 `ui-red-test.log`、`heartbeat-red-test.log`。

## 父会话 Cua 真实窗口复核

运行本 worktree 构建的 `--preview --preview-quota-history --preview-narrow`，不是已安装生产 App。通过 list_windows 确认本次 PID/窗口，先展示镜像，再执行后台像素/AX/键盘动作，并回读截图和 AX 文案验证：

1. 280pt 内容宽的六组双柱可读，历史在每日用量之后、MCP 之前；纵向滚动可以看到完整历史与 MCP，未将截图全高模式当成真实视口验收。
2. 实际点击第一列：详情变为「02/22 · 额度窗口变化（原因未确认）」「最后观测剩余 4,869 / 10,000」；当前轮的待确认文字没有泄漏到该闭合段。
3. 按 Left 跨到前一页：页码变「历史6轮」，选中 02/15 的周卡段；旧页「更早的周期」禁用、「更新的周期」可用。
4. 点「更早」：展示「历史1轮」，全部13轮已加载后「加载更早记录」禁用，不生成假柱。
5. 折叠后图表与详情消失、MCP上移；重开页位置和固定选择仍在。点击返回最新恢复最新页。
6. 当前候选的虚线框和固定选中的实线框分别可见。截图为真实原生窗口，不是 HTML 示意图。
7. 退出只针对本次创建的预览进程；退出按钮的 AX 返回在进程终止时失败，经 `ps` 确认该 PID 已不存在，没有重复触发或结束生产 App。结束本次 Cua session 与镜像。

截图目录：`/Users/Chester/.proma/agent-workspaces/glmusage/2697bd2e-0b15-4ceb-b771-148976e9c17b/generated-images/`。`glm-narrow-selected.png` 是实际点列后完整原生窗口；`glm-quota-history-native.png` 是该图中历史卡与 MCP 的裁切副本，仅用于展示，不作为输入坐标依据。其他证据含 `glm-native-cross-page.png`、`glm-native-earliest.png`、`glm-native-folded.png`、`glm-native-reopened.png`。

本轮重点重验 280pt 浅色实际视口；340pt/暗色/不同背景的此前验收记录见 2026-11-12 报告，本轮不把它们冒充全部重新操作。

## 知识维护与未验证范围

- 活动 worktree 的 AGENTS.md 从 6083 非空白字符瘦身到 2916，保留入口、命令与红线；协议细节、部署 SOP 与旧故障证据移到项目 `operations-and-protocols.md`，索引保留既有 Proma 平台路由并增补专题路由。历史部署事实未被标记为本次重新实测。
- 未做真实账号跨周、真实双 Key 切换、真实用卡或线上接口验收；未做旧 macOS 实机或真人 VoiceOver 听读。
- 既有 Store 的符号链接检查 TOCTOU 威胁边界、生产主队列投递假设仍按 `docs/project/17-quota-cycle-history.md` 明示，没有扩大成完整本机攻击防护承诺。

## 06:41 用户参考图后的排版调整

- 每组图柱下先日期、后已用百分比；底部仅保留周期时间/状态一行，精确数值与积分移入悬停提示/辅助功能。维持绿色主题、六组分页和原有卡片总高度量级；图表自身增加14pt用于百分比，同时去掉原14pt数值详情行。
- 新增 `chartPercentageLabels`：0%、100%、普通整数百分比、<1%、>99%、无效值，以及220/280pt图内宽下日期/百分比/柱体不重叠并逐列居中。先确认因新展示接口缺失而编译失败，再实现通过。
- 重新构建、自检 PASS、peak-test 8/8、签名通过；历史 unittest **31项 / 2.923s / OK**。本次没有再次运行全部脚本测试，不将前文64项结果改称本次新增后的总回归。
- 340pt/280pt两种面板的 `--preview-popover --preview-quota-history --preview-quota-history-test` 均通过，增加“不存在独立已用详情行”的检查，原有翻页/选择/焦点/折叠仍通过。
- Cua再次打开本worktree的280pt假数据原生窗口，实际滚动到底部，截图确认六列日期下分别为51%、59%、66%、73%、81%、88%，底部只一行状态、MCP可达。仅退出本次预览PID，未安装或触碰生产进程。
- 证据：会话工作台 `generated-images/date-percent-native.png` 为完整窗口，`generated-images/quota-percent-under-date.png` 为历史卡裁切；日志为 `review-logs/date-percent-*.log`。已同步CHANGELOG与功能说明，不涉及额度状态机或存储口径变化。

## 07:33 用户授权后的本机部署

- 用户明确要求本地部署。旧安装为 `~/Applications/GlmUsage.app` / `v1.4.1`，目标 LaunchAgent 为 `com.local.glm-usage`，未操作其他usage应用或修改plist内容。
- 先验证构建源码未晚于二进制、self-test PASS、peak-test 8/8、签名通过；新旧版本均使用同一本机 `local-codesign`。完整旧版本备份到会话工作台 `deployment-backups/2026-11-13-0733/GlmUsage.app`，替换时保留原bundle为同目录 `replaced-GlmUsage.app`。
- 首次交互终端受zsh提示符配置影响，停止目标后未完成替换；核对目标/暂存/备份和服务状态后，通过独立bash脚本继续部署。新版本替换并bootstrap后，等待12秒确认本次PID驻留，且诊断mtime和version均为本次新进程写入。
- 已安装版本为 `v1.4.1-3-gdc60239-dirty`，PID 51246，实际可执行文件为 `/Users/Chester/Applications/GlmUsage.app/Contents/MacOS/GlmUsage`。安装二进制SHA-256与worktree构建一致：`c9c6238d5eb558fa92fc20fce83076765d43b306ef5d6efe0d737bf484e817d5`。
- 真实App正常取得周额度并刷新：2026-11-13 07:39:33 GMT+8的status更新时间和周额度最后成功时刻一致。通过系统菜单栏打开安装版面板，Cua精确绑定本次PID/窗口，实际截图显示首条本日历史、日期下方的已用百分比和首次观测提示，真实MCP/日用量正常。未开假数据模式、未运行`--once`或真实消费卡。
- 真实popover可截图但AX窗口绑定不可用，因此本次只做该窗口的观察，不以空AX树证明交互；此前假数据原生事件回归覆盖键盘/鼠标。历史由本次启动开始记录，仍不代表真实跨周已验证。
- 截图 `generated-images/glm-installed-20261113.png`；仅历史卡裁切为 `generated-images/glm-installed-history.png`。含账号/用量的截图仅留会话工作台，不写入源码仓库。安装版保持运行，未提交、合并或公开发布。

## 07:45 对齐 CodexUsage 的三点优化

- 1–5条短历史也按六列槽位靠右排列，最后一组触及最右边界；不生成占位历史。新增 `shortHistoryRightAligned` 测试先复现失败，再通过。
- 去掉柱组实线/虚线描边，仅保留柱体区域的浅绿圆角底色；日期、已用百分比位于底色下方。当前轮与鼠标/固定选中仍用透明度区分，不改变数据语义。
- 首轮仅在显示时用 expectedResetAt−7天推算起点，图下标 `~MM/dd`，当前文案为「推算MM/dd–至今（预计MM/dd） · 进行中」；真实firstObservedAt和边界证据不改写。悬停及辅助功能仍说明实际开始未知，不能声称完整观测了7天。新增 `compactCycleWording` 覆盖示例日期、跨年、结束段及未知说明，先失败再通过；计划执行偏差与当前说明/CHANGELOG同步更新。
- 完整Python回归 **67 tests / 57.542s / OK**（33项历史测试），构建、自检、peak-test 8/8、签名通过；常规340pt、窄280pt及深色原生历史事件测试均通过。
- 已备份此前本机版本至会话工作台 `deployment-backups/2026-11-13-codex-alignment/` 并更新安装。新PID56876，安装/构建二进制SHA-256同为 `b7202fb4cc10160981bf6d870babc9fd03512165fa5e57744b427c557191db84`。
- 更新后12秒初始驻留/诊断检查通过，但随后真实App受系统钥匙串授权框阻塞：SecurityAgent要求用户为本应用的 coding-plan 条目输入登录钥匙串密码。已将系统窗口展示并请用户亲自在系统界面完成，未代填、点击授权、改ACL或绕过权限；本轮真实安装界面复核暂未完成，不能用假数据事件测试代替授权后的真实刷新验证。
