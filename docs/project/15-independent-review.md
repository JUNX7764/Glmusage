# 主会话独立验收结论

日期：2026-11-06

## 结论

**离线实现与本轮代码审核已完成；完整生产功能尚未完成，不可据此发布。**

实现位于独立 worktree 的 `feature/glm-usage-insights`，未提交、合并、发布或部署。原 main 未改生产代码，既有运行应用未被替换。

## 独立验证（最终二进制，不只转述开发 Agent）

- `build.sh`：PASS；存在离线 GUI 测试函数中 fail() 后冗余 exit(1) 的 unreachable-code 编译警告，不是零警告构建。
- `--self-test`：PASS，包含日序列/完整小时网格/比较/邮箱纯函数 fixture。
- `--peak-test`：20/20 PASS。
- Python 脚本回归：22 tests OK，37.159 秒。
- 三份 shell 脚本语法：PASS。
- `--preview-popover-test`：PASS；日志记录一次 `env-close recovered`，因此准确表述为带环境关闭恢复的通过，不宣称完全无外部干扰。
- 间隔 5 秒后 `--preview-daily-test --preview-daily-gaps`：PASS，覆盖 Tab 到达、列命中、零/缺失、离开保留、点击、方向键与无障碍值。
- `git diff --check`：PASS。
- quota renderer、resetHeading 至重置卡块、footer 逐字比对：与基线完全一致。峰谷/套餐到期包含在冻结块内。
- 已查看开发截图：正常336、长邮箱/套餐280、每日空态、基期0与窄屏比较条；已修复 badge 真圆角。

## 代码审查修复

- 不再把单一 API key 候选当成与 OAuth user_info 同一账号的证据；有环境变量 key 或任何 api-key 候选时隐藏邮箱。只在纯 bigmodel OAuth 回退且 token 可用时读取 rawProfile.email；顶层 email 和 username 回退不采信。
- 邮箱环境变量布尔门禁反转已修复，决策纯函数包含集成参数矩阵；预览不读凭据。
- 套餐 badge/比较条真正使用 cornerRadius。
- 图表键盘路径不再只靠测试强行 makeFirstResponder，增加 key view loop 和 Tab 测试。
- 日桶需完整小时网格，缺小时不当完整日；解析失败/旧值以简短待更新表达，缺失不补0。

## 尚未通过的生产门禁

1. `productionGateConfirmed=false`，真实每日响应格式、粒度、归日时区与稀疏/密集网格未验证。生产当前只显示「暂不可用／数据不足」，预览柱图不代表生产已可用。
2. 现有滚动30天响应最多可靠覆盖29个完整自然日，最老日保守缺失；未改周期统计窗口或增加请求凑满30日。
3. 真实邮箱字段存在性未核实，取不到隐藏；切账号隔离与日数据修订尚需在激活前验证。
4. 性能仅有开发者短时preview CPU/RSS及命令壁钟证据，未完成PRD的10分钟静置和1分钟持续交互热路径测量，不宣称能耗验收完整通过。
5. 未执行真实凭据查询、`--once`、生产GUI驻留、真实更新或用卡。既有生产实例运行，不得并发真实`--once`或自行停应用。

## 下一步

如用户安排真实接口验收，先确认范围与并发隔离方案，只读核验每日序列并固化脱敏fixture；按结果决定能否激活，不直接把开关置true。合并、提交、发布与部署仍需分别授权。

最终独立测试日志：
`/var/folders/hr/cd0kr4n925n_zqkx7dsb2n8r0000gn/T/zcode-bash-wrTsjs/sess_01e6e95a-f2e8-44c4-afde-95e92513b911/call_uZJCJXSz6T4marCamV1sIXxE-stdout.log`

## 真实接口验收（主会话，2026-11-07 00:00 前后完成）

只读探针（独立 Swift 程序，复刻 CredStore/Fetcher 同款请求；仅输出结构，不打印任何 key/token）：

- `GET /api/monitor/usage/model-usage`（30 天滚动窗）：HTTP 200 / code 200。
- `data.granularity = daily`；`x_time` 为本地自然日 `yyyy-MM-dd` 标签：31 个（首标签=请求起点日）、严格递增、零缺口、含今日部分累计。
- `modelDataList` 3 个模型，`tokensUsage` 长度全部对齐，无 null/负值/非有限值，无重名模型。
- 逐日求和与 `totalUsage.totalTokensUsage` 精确配平（同值）。
- **关键口径更正**：真实响应为日粒度，与开发阶段假设的小时粒度不符（公开实现 CodexBar zai.js 的小时假设不成立）。Gate 存在的意义即在此——未盲翻开关。

### 由此的代码适配（主会话执行，非开发 Agent）

- `parseTimeline`：标签格式改为 `yyyy-MM-dd`（round-trip/严格递增/长度对齐/非负有限/重名拒绝等全部校验保留）。
- `frame`：删除本地小时网格推断与 DST 用例（服务端已按自然日汇总），改为日粒度直映射；桶范围/今天排除/coverageStart 准入口径不变。
- `productionGateConfirmed = true`（附验收证据注释）；self-test 断言同步翻转防口径漂移。
- 冻结区四块（quota/resetCards/peakCard/footer）与基线 b0a32a8 逐字节比对：全部 IDENTICAL。
- 回归：build PASS、`--self-test` PASS（含新日粒度 fixture）、`--peak-test` 20/20、Python 22 tests OK。
- 已部署本机 `~/Applications` 验证（用户目视验收中）。

### P2 修复与排障记录（主会话，2026-11-07 凌晨）

- P2-1（canvas a11y element）：已试加 `setAccessibilityElement(true)`，实测破坏 Tab 可达断言（Full Keyboard Access 下 Tab 遍历走 a11y 树），**回退**，代码留注释说明；VoiceOver 用户仍可读日期/数值文本标签。
- P2-2（NSMenu fallback 标题）：已同步为「用量情况」。
- P2-4（14 号报告过时）：顶部已加口径更正指针。
- P2-5（frame 桶键 DST 失配 / -0.0%）：frame 全部键统一 Y/M/D 分量往返（dayKey）；outcome 阈值 `abs(pct)<0.05 → 持平`，self-test 补 3 条断言（其中一条在本轮排障中实际抓到过二分回退遗漏，防回归价值兑现）。
- P2-3（scrollerStyle 披露项）：维持现状（有记录在案的回归修复动机，footer 块本身逐字节一致）。
- **排障**：`--preview-daily-test` 连续 FAIL 经二分排除全部代码改动后，定位为环境因素——**屏幕锁定（CGSSessionScreenIsLocked=1，00:24 起）使 agent app 无法取得 key window**，键盘事件被整体丢弃；历史三次 PASS 均在解锁状态。测试入口已加 key 门控（激活+重开面板+轮询，key 前不捕获视图引用）与结果 sidecar；AGENTS.md 已补运行条件。
