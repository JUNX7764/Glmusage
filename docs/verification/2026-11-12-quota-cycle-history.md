# 周额度周期回顾 验证报告（2026-11-12）

- 分支：`plan/glm-quota-cycle-history-20261112`（worktree `2697bd2e-0b15-4ceb-b771-148976e9c17b/plan-worktree`）
- 验收日期：2026-11-12；全部为离线假数据验证，未联网、未读真实凭据、未跑 `--once`、未真实用卡。
- 截图与日志临时产物：`/Users/Chester/.proma/agent-workspaces/glmusage/8bfa8db4-934f-4c26-a4d6-0b04f21793e2/shots/`（不写入仓库）。

## 1. 离线回归（Task 13 Step 1）

| 命令 | 结果 |
| --- | --- |
| `./build.sh` | 成功（v1.4.1-dirty，arm64） |
| `./GlmUsage.app/Contents/MacOS/GlmUsage --self-test` | PASS |
| `./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test` | 8/8 PASS |
| `python3 -m unittest discover -s tests -p '*_test.py'` | 61 tests OK（77.9s） |
| `python3 -m unittest discover -s tests -p 'quota_cycle_history_test.py' -v` | 27 cases 全 PASS（含 orderedLoad、oldConnectionOperation、apiKeyAttributionDefence、thousand_record_store_round_trip、coordinator_heartbeat_and_write_failure、store_safety、store_nested_and_symlink、clock_rollback_pending 等） |
| `bash -n build.sh scripts/update.sh scripts/release.sh` | 无输出（语法通过） |
| `lipo -archs GlmUsage.app/Contents/MacOS/GlmUsage` | arm64 |
| `codesign --verify --deep --strict GlmUsage.app` | 通过 |

持久化与故障保护由 fixture 覆盖：临时目录 save→load 往返（1000 轮）、损坏文件保护、未来 schema 拒绝、嵌套验证、symlink 拒绝、不可写 writer 降级为未保存状态、心跳 5 分钟节流。fixture 全程使用固定 epoch 临时目录，未读写真实 `quota-history` 数据与凭据。

## 2. 隔离原生预览矩阵（Task 13 Step 2）

同类 GUI 进程启动间隔 ≥5s；预览进程写完截图自动退出，逐个验证退出码 0。

| 变体 | 命令（`--preview --preview-popover-ui` 基础上追加） | 观察 |
| --- | --- | --- |
| long（13 轮 + pending 候选） | `--preview-quota-history` | 6 组双柱/页、`‹ 最近 6 轮 › 更早`、末列 current 高亮、详情「窗口变化待确认 · 87.96% · 1,204/10,000」 |
| dark | `--preview-dark --preview-quota-history` | 深色下柱/文字/详情行全部可读（dynamic color） |
| narrow 280pt | `--preview-narrow --preview-quota-history` | 六柱完整、日期标签不换行、详情行不挤压 |
| empty | `--preview-quota-history --preview-quota-history-state=empty` | 空态引导文案「从首次成功读取周额度后开始记录 / 历史按套餐连接保存；更换 Key 不自动合并」，最近 0 轮 |
| short（1 轮） | `...-state=short` | 单列 01/04*（星标=首次观测非真实起点），「开始时间未知」 |
| volatile / protected / unsaved | `...-state=volatile/protected/unsaved` | 状态行分别显示「仅保留本次运行」「历史文件受保护」「历史未保存」（像素 diff 仅状态行一行文字差异） |
| 背景 solid / classicMaterial / liquidGlass | `--preview-background=...` | 三种背景全图差异，卡片与图表可读性保持 |
| 系统时区 | `TZ=America/New_York` | 显示时间随 TZ 变化（本地时区口径），结构不变 |
| 跨年 | long fixture 基期 2027-01（相对当前 2026-12 跨年） | 01/xx 日期标签与分页正常 |

全部 md5 互异，`--preview-quota-history-state` 各态真实生效（GUI 测试入口以 `state=short` 触发「13-cycle fixture unavailable」FAIL 反证参数解析正确）。

**验证期间发现并修复的预览基础设施问题**：`--preview-screenshot` 原渲染 `contentView` 视口；面板内容超过 0.82 屏幕上限时由 scroll 承接，底部「额度周期回顾/MCP」卡落在视口外，截图矩阵无法覆盖。修复（`GlmUsage.swift` 截图分支同函数）：`--preview-screenshot` 且非 popover 形态时不做屏幕高度截断，窗口直接取内容全高（离屏缓存渲染不受超屏影响）。仅影响预览截图路径，生产行为不变；修复后 `--self-test`、`--peak-test` 复跑通过。

## 3. GUI 事件回归（真实事件派发，非 handler 冒充）

逐个运行、进程间 ≥5s，全部 PASS：

```bash
--preview-popover --preview-quota-history --preview-quota-history-test   # sidecar /tmp/glm_quota_history_test_result.txt = PASS, exit 0
--preview-popover-test                                                    # PASS（live resize/锚点/滚动恢复/控件/异步刷新/开合/左右边距）
--preview-daily-test --preview-daily-gaps                                 # PASS（悬停整天宽命中/零缺日/离开保留选中/点击/键盘/a11y/重开）
--preview --preview-update-test                                           # PASS（居中卡片/滚动/刷新/取消/安装预览/关闭/背景）
```

history 事件测试覆盖：Tab 到达 canvas（key view loop）、悬停整列（含柱间空白）、点击固定、悬停临时改选、←→跨页焦点跟随、六列几何断言。

## 4. Cua 真实 AppKit 验收（Task 13 Step 3）

对 worktree 构建的预览进程（`--preview` 窗口形态 + `--preview-popover` 形态，均假数据）通过 Cua Driver 真实鼠标/键盘事件验收；全程未触碰用户生产中的 GlmUsage（~/Applications，PID 76373），验收结束仅退出本次创建的预览进程。

| # | 项目 | 结果 |
| --- | --- | --- |
| 1 | 点列固定选择 | 第 1 列点击后高亮固定，详情「窗口变化待确认 · 观测开始 02/22 02:13 · 额度窗口变化（原因未确认）· 已用 51.31% · 剩余 4,869/10,000」与 fixture i=7 精确一致 |
| 2 | 悬停临时改选 | 真实指针移至第 3 列：详情变 03/08（规格变化 · 65.97% · 3,403/10,000，与 fixture i=9 一致），固定列选中框保留 |
| 3 | 移出恢复 | 指针移出历史卡：详情恢复固定选择 02/22 |
| 4 | ‹ 翻页 | 「历史 6 轮」页显示 01/11–02/15（跨年日期正常），详情保持 current 03/29 |
| 5 | 「更早」扩展 | 13 轮全部可浏览；最旧页「历史 1 轮」仅 01/04*（星标首次观测），不伪造 |
| 6 | 键盘 → 跨页 | 「历史 1 轮」页按 Right：自动翻页至「历史 6 轮」且选中移动到 01/11 |
| 7 | 键盘 ← 反向 | 回「历史 1 轮」页 |
| 8 | 折叠/重开 | 折叠为标题行（MCP 上移无残留）；重开后页锚与选中 01/04* 保留 |
| 9 | 滚动到 MCP | 历史卡展开态下滚动顺畅，MCP 卡可见、内容不重叠 |
| 10 | Esc 关闭 | popover 形态按 Esc 后窗口关闭（真实键盘事件） |
| 11 | 外点关闭 | popover 打开后点击面板外空白处，transient 自动关闭 |
| 12 | 340/280、浅/深 | 340pt（浅/深）与 280pt 截图矩阵逐一核对，六柱布局、详情行、状态行均不挤压不截断 |

340pt 展开态全高截图（long.png）确认卡片顺序：每日用量 → 额度周期回顾 → MCP 工具，既有峰谷/重置卡/用量卡顺序与材质不变（A1）。

## 5. Coordinator 投递审计结论（checkpoint 遗留项 1）

核验结论：现有实现已具备所需防护，未发现需要改代码的缺陷。

- 生产路径 `deliveryQueue = .main`：`publish` 的 generation 检查与 `deliver` 同在主队列串行执行，且 `activate()` 的 `activation &+= 1` 在调用线程同步完成（`bindHistoryContext` 全程主线程），「检查通过后、投递前被切换」的窗口不存在。
- 投递侧按 generation 丢弃过期快照：`orderedLoad` case 断言「旧 A 回调不应用到 B」「最新 UI 不被过期快照覆盖」。
- A→B→A 分区复用：`activations[generation]` 按代隔离 entry，迟到的 `record` 写回原分区且 `attributionProven` 降级（`oldConnectionOperation` 断言旧分区保留操作事实但不获得 proof、不泄漏到 B）。
- 已知限制（记录于 `docs/project/17-quota-cycle-history.md`）：`GLMQuotaCycleSnapshot` 不携带连接标识，防过期完全依赖 Coordinator 的 generation 检查；测试以自定义 deliveryQueue 注入时由 harness 保证语义。

## 6. Store 静态符号检查限制（checkpoint 遗留项 2，如实标注）

`GLMQuotaCycleStore.location()` 的 lstat 检查仅覆盖检查时刻：`load` 的 `Data(contentsOf:)` 会跟随符号链接，检查与读取之间存在 TOCTOU 窗口。`save` 路径以 `O_EXCL` 临时文件 + `rename` 原子替换（rename 替换目标 symlink 本身而不写入其目标），写侧不扩大该窗口。威胁模型定位：防御误配置/意外符号链接（如同步盘占位文件）与普通数据损坏，不承诺对抗已拥有本机用户权限的活跃攻击者。分区名强制 64 位十六进制白名单，根目录固定于 App Support 且 0700。该限制已在 `docs/project/17-quota-cycle-history.md` 与本文档如实标注，不声称安全完整。

## 7. 未验证项与边界

- 真实账号跨周长期采样、真实网络接口行为、真实重置卡与消费协议线上联动：本次不验证（不跑 `--once`、不真实用卡），需后续单独安排网络验收。
- 真实凭据多连接 A/B 切换仅由 fixture 与 GUI 假数据覆盖，未用真实双 Key 验证分区隔离。
- 液态玻璃背景在本机（macOS 26+）渲染通过；更旧系统的回退为代码路径断言，未做旧系统实机验证。
- VoiceOver 语义：canvas 提供 AX label/value（含日期精度、结束原因、已用%、余额/分母），GUI 测试有 a11y 断言；未做真人 VoiceOver 听读验证。
- 预览矩阵中的时间敏感文本（倒计时/刷新时间）使同 state 两次截图存在少量像素噪声，不影响结构对比结论。
