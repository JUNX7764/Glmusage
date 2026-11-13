# 五项 UI 精修：本地部署记录

日期：2026-11-14 07:40–07:42（Asia/Shanghai）。用户于本会话明确要求“本地部署”。

## 结论

已部署并重启用户原安装副本。新进程持续驻留，真实额度、Token、订阅、重置卡查询和 MCP 刷新成功，最终诊断无错误、无过期标记。未合并 main、推送或公开发布。

## 目标与构建

- 源 worktree：`/Users/Chester/.proma/agent-workspaces/glmusage/ca6cf371-bcd1-4227-99b5-1db7487f7cdd/ui-refinements-worktree`。
- 部署源码提交：`b171551`，分支 `plan/ui-refinements-20261113`；部署前工作树干净。
- 版本：`v1.5.2` → `v1.5.2-8-gb171551`（界面的短版本号仍显示 v1.5.2）。
- 安装路径：`/Users/Chester/Applications/GlmUsage.app`。
- 启动项：`gui/501/com.local.glm-usage`，沿用实际已加载 plist；没有修改 ProgramArguments、KeepAlive 或其他应用的启动项。
- 原 PID：69515；新 PID：91701，实际命令路径等于上述安装包内的可执行文件。
- 源包与安装包可执行文件 SHA-256 均为 `9ea737f0d6ffeb1c1e371db1fa07c2f0a0e8c2c866dc944651d608cb848a547e`。
- 原版 SHA-256：`9740c79ed133ca7950d00f3779eae8935ccd05de44cbf30106053c84ffc54de4`。

## 备份与换包

备份根目录：

`/Users/Chester/.proma/agent-workspaces/glmusage/ca6cf371-bcd1-4227-99b5-1db7487f7cdd/deployment-backups/20261114-074021/`

其中 `GlmUsage.app` 是校验过的完整旧版拷贝；`original/GlmUsage.app` 保留换包时移出的原安装。`receipt.txt` 保存版本、哈希、起始时间与新旧PID。先用 ditto 完成备份和暂存校验，再精确 bootout 目标 LaunchAgent、确认原PID退出、换包并 bootstrap/kickstart。同一脚本包含换包/启动失败时恢复旧包的错误处理；本次没有触发回滚。

未按进程名模糊 kill，未手工修改凭据、用户额度历史、pending 用卡状态或证书/钥匙串信任；正常启动后的自动观测与查询按原逻辑运行。新旧签名均为既有 `local-codesign`，designated requirement 完全一致。

## 实际检查

- 部署前确认二进制不早于所有 Swift/build.sh/Info.plist 输入；源包签名通过。
- 本轮重跑 `--self-test`：PASS；`--peak-test`：8/8 PASS。不重新宣称昨晚72项测试是今天又跑的，完整实现验收见 `2026-11-13-five-ui-refinements.md`。
- 安装后 `codesign --verify --deep --strict` 成功，源/安装哈希一致。
- 等待至少12秒检查新进程驻留和新版本诊断。首个12秒样本的 quotaError 非空，未将其写成刷新正常；未改凭据，后续后台刷新已成功。
- 07:40:58，五小时/周额度、今日/7日/30日Token、MCP、订阅、两种重置卡查询均有本次启动后的成功时间；07:42:24，五小时与周额度再次成功。
- 07:42:33 复核：PID91701仍运行；诊断版本正确、updatedAt持续推进、quotaError为空、各项errors为空、stale全部false。
- 真实 `status.json` 只按明确安全字段读取，未输出凭据或原始认证信息。启动初次及最终健康摘要分别保存在备份目录 `startup-health-summary.json` 与 `health-summary.json`。

## 实际安装界面

用 Cua 精确确认新PID91701、窗口39008，先展示镜像再捕获真实安装版画面：面板显示真实用量；每日柱微圆角、涨跌chip、单根额度槽和独立历史图标均可见，版本与诊断一致。不是假数据预览，也没有运行 `--once`。

该真实Popover的AX表面无法解析，因此本轮只观察确切窗口截图，没有绕过拒绝强行输入；不把空AX树说成交互通过。320ms动画及原生点击/键盘已由同一构建的前一轮隔离假数据验收覆盖，本轮未再次真实点击重置卡或系统授权。

截图保留于会话工作台 `generated-images/glm-installed-20261114.png`，含用户真实用量，不放入代码仓库。部署脚本保留于会话工作台 `deploy-local-20261114.sh`。本次Cua session/镜像已结束，安装版保持运行。
