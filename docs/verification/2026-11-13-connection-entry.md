# 连接入口自动化优化验收

日期：2026-11-13；用户08:34提出自动化优先，08:35确认按方案实施。继续在现有 `plan/glm-quota-cycle-history-20261112` worktree 开发，不新开分支、不合并主分支、不提交/推送。开发验收阶段未再次替换已安装App、未读真实凭据或授权真实钥匙串、未消费卡；后续09:48用户授权的本机部署见文末。

## 变更

- 删除底部「套餐设置」；顶部「GLM 用量」改为无边框原生按钮，默认保持标题外观，悬停提示「连接设置（默认自动读取）」，提供键盘/辅助功能语义。
- 正常状态无连接配置按钮；凭据缺失/格式不支持、HTTP401/403及钥匙串锁定等明确故障时，显示「修复连接」。锁定优先解锁对应来源，不先要求填Key；普通HTTP500/超时继续原自动重试，不显示手动Key修复引导。
- 保留原手动Key验证、保存、取消与切回自动读取；修正无解锁按钮时「断开连接，改用自动读取」的响应序号。未更改凭据来源优先级，不自动删除或切换用户已保存的Key。
- 移除启动后1.5秒自动交互解锁：启动与后台只non-interactive读取，必须用户点击修复/设置才允许系统授权，避免授权模态框阻塞主界面。未降低Keychain权限或改ACL。
- 预览修复只显示模拟结果，不读真实Keychain；NSAlert预览验证不提交任何Key或连接请求。

## 自动验证

| 项目 | 实际结果 |
|---|---|
| `./build.sh` | 成功，原arm64/macOS13/签名策略不变。 |
| `--self-test` | PASS；新增10组连接故障路由断言。 |
| `--peak-test` | 8/8 PASS。 |
| Python全部回归 | 67 tests / 53.440s / OK。 |
| bash语法与codesign严格校验 | 通过。 |
| `--preview-connection-test` | PASS：正常态底部无入口、标题控件可达、原生设置弹窗、取消返回、锁定/备用来源路由、重置凭据独立故障、HTTP500不引导配置。 |
| `--preview-connection-test --preview-narrow` | PASS，280pt布局可用。 |
| 既有Popover、每日图、周额度历史、更新预览回归 | 全部PASS，进程逐个执行且退出后≥5s再启动下一项。 |

新增回归先在旧界面确认 `FAIL normal state exposes connection controls`。模态检查最初使用主队列回调，无法重入启动测试的主队列任务；改为RunLoop Timer加入common/modalPanel模式检查，再返回取消响应后通过。该回归使用NSButton.performClick激活真实原生控件，并程序化返回取消，**不声称等同硬件鼠标点击**。

日志：会话工作台 `review-logs/connection-entry-*.log`、`review-logs/connection-regression-*.log`。

## Cua 原生窗口验证

只操作本次创建的独立假数据预览，不碰已安装生产进程：

1. 常规面板实际截图与AX确认：顶部为原生GLMConnectionTitle按钮，有悬停和辅助功能标签；底部仅保留刷新、自启、退出，无套餐设置。
2. 通过顶部AX入口观察到原生设置窗口产生；另用带凭据故障的预览实际像素点击「修复连接」，窗口出现。截图确认标题「连接设置」、自动读取说明、安全输入框、验证/取消/获取Key按钮；未填写密钥。
3. NSAlert有大阴影CG窗口与较小实际AX窗口：大窗口可截图但AX unresolved。切换到较小真实窗口读取AX树，执行「取消」后再次列窗，确认只剩主窗口。未通过其他工具绕过权限拒绝。
4. 正常态/异常态截图已实际回读。结束Cua session与镜像，仅结束本次预览进程。

证据在会话工作台 `generated-images/`：`connection-hidden-entry.png`（正常态）、`connection-repair-entry.png`（故障入口）、`connection-settings-dialog.png`（原生设置弹窗）。

## 文档与边界

已更新README安装引导、DEVELOPMENT、架构、CHANGELOG及AGENTS中的交互授权红线和测试入口；项目运维专题补充本轮已验证的决策与模态测试/窗口定位经验。

开发验收阶段尚未验证真实用户连接、真实Keychain解锁/保存/断开以及此版本本机部署；未执行`--once`，未更改系统凭据或主分支。新入口方案完成于当前worktree，与此前已安装的周期图版本明确区分。

## 09:48用户授权后的本机部署

- 精确替换 `/Users/Chester/Applications/GlmUsage.app`；仅重启 `gui/501/com.local.glm-usage`，未操作其他usage应用、未改LaunchAgent配置或系统凭据，未提交/合并/推送。
- 旧版本备份：会话工作台 `deployment-backups/2026-11-13-connection-entry-0948/`，保留 `GlmUsage.app` 和替换前的原包 `replaced-GlmUsage.app`。
- 构建源码时间核对、暂存/备份/安装包严格签名校验均通过。安装版与worktree二进制SHA-256均为 `169abe831d0652879d4248bfc8c8415db5f25b7dc19cc011ab4c940674f5aa5e`；版本仍为 `v1.4.1-3-gdc60239-dirty`。
- 新PID `86756` 在实际安装路径驻留12秒后诊断已更新，09:56复查已连续驻留约5分钟，诊断更新时间推进到 `2026-11-13T01:56:29Z`，不是旧进程或旧诊断。
- 当前真实连接尚未恢复：诊断为「已保存的套餐连接暂不可用，请重新连接」，额度最近成功时间为空；未自动弹出授权或代为解锁。用户需点击面板「修复连接」，亲自在系统窗口中完成授权。
- Cua确认运行实例无可见窗口；对该PID的唯一菜单栏项进行AX点击后仍未获取可见Popover，因此不宣称本轮已验证安装版真实窗口或系统授权交互。此前假数据原生/Cua测试仍有效，不能替代此项。已结束Cua镜像与session，保留生产App运行。

结论：本机部署完成、进程与诊断健康；真实数据恢复和真实窗口交互仍待用户完成授权后复核。
