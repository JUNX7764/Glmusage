# AGENTS.md

## 项目与入口

GlmUsage 是 macOS 13+、Apple Silicon 的 GLM Coding Plan 原生 AppKit 菜单栏应用，无第三方包依赖。Bundle / LaunchAgent：`com.local.glm-usage`；产物 `GlmUsage.app`。

| 入口 | 职责 |
|---|---|
| `GlmUsage.swift` | CredStore、Fetcher、Peak、更新、AppDelegate 与原生面板组装、离线自检 |
| `PanelCustomization.swift` | 面板卡片布局模型与卡片设置视图（显隐、排序、恢复默认） |
| `Sources/GLMQuotaCycle*.swift` | 周额度历史：观测、连接分区、版本化存储、协调器与原生视图 |
| `build.sh`、`scripts/update.sh`、`scripts/release.sh` | 本地打包、就地更新、发布 |
| `tests/` | PATH mock 脚本回归与独立 Swift 历史夹具 |

用户说明从 `README.md` 进入；当前工程事实见 `docs/DEVELOPMENT.md`，架构/标准/发布见 `docs/project/02-architecture.md`、`07-standards.md`、`10-release.md`，额度历史见 `17-quota-cycle-history.md`。判断行为优先源码与测试，不能把计划、旧文档或历史快照当作已实现规格。

## 构建与验证

需要 Xcode CLT 和 macOS 26+ SDK；部署目标为 macOS 13、arm64。build.sh 把主文件符号链接为 main.swift，自动收集根目录与 `Sources/` 的 Swift 文件；不要丢失 top-level 入口或新增第二个 main。签名优先本机稳定 `local-codesign`，不为普通开发修改证书或系统信任。

```bash
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test
python3 -m unittest discover -s tests -p '*_test.py' -v
bash -n build.sh scripts/update.sh scripts/release.sh
codesign --verify --deep --strict GlmUsage.app
```

改代码后必须重新构建并跑 self-test、peak-test 和相关回归，报告实际结果；改构建/发布脚本时 Python 与 Shell 检查也必须跑。`--self-test` 用临时目录和假数据，不读真实凭据、不联网；`--once` 会读真实凭据并联网，只在明确安排网络验收且确认无并发实例时运行。原生假数据 GUI 回归（popover、卡片设置、每日图、额度历史等）逐个运行、退出后间隔≥5s，完整命令见 `docs/DEVELOPMENT.md`；键盘测试须屏幕解锁且取得 key window，拿不到焦点不得报通过，CLI/固定数据截图不替代真实 AppKit 交互。部署前实际 GUI 驻留约10秒并确认本次 PID 与诊断更新。不得同一调用对同一存储属性的两个子字段同时取 inout；用纯函数返回后顺序赋值。

## 跨任务红线

- 与用户用中文，技术细节按需展开；源代码职责轻量分层，不向主文件继续堆叠新业务算法。
- 凭据文件只读；启动/后台钥匙串读取 non-interactive，不自动弹授权框，交互解锁仅由用户点击修复/连接设置触发。Key、token、认证头、原幂等 key 不进代码、提交、日志或诊断状态。preview/自检使用假数据、临时根，不读真实凭据/pending/history，不初始化真实历史仓库。
- 手动套餐 API Key 与 ZCode 登录态/邮箱不一定同账号。历史 API Key 按连接隔离、更换 Key 不自动合并；OAuth 回退仅本进程记录，未证实同身份的用卡不得标主动重置。
- 额度独立10s刷新，慢项5min，手动全量；失败保留旧值与原成功时间。历史只收本次有效无 warning 的 fresh.week，不拿合并缓存当新样本，不从 Token/赠送用量反推积分，不补假周期或漏周零柱。
- 重置卡消费仅用户点击并二次确认，preview 禁用，绝不自动触发；成功严格 code==0 且 data.used==true；结果未知复用原幂等 key，成功后保留既有3秒补刷。5小时卡不能结束周额度历史。
- Peak 固定 Asia/Shanghai，高峰工作日14:00–18:00全价、其余/周末5折；修改活动日期必跑 peak-test，不二次对接口积分打折。
- 重要系统配置、凭据写入、真实用卡、安装/重载、公开发布与危险 Git 操作须获相应授权。不得混淆 worktree 构建与用户已安装 App，不结束用户生产进程。更新器只处理目标 tag/目标 App 及其实际 LaunchAgent，禁止按名称模糊 kill；面板更新进度原位展示，不弹独立窗口、不抢焦点。
- 多个 usage app 部署/重载须错开≥5s，避免菜单栏图标叠位；KeepAlive 使用 SuccessfulExit=false，正常退出不保活、崩溃保活有节流。具体操作与旧问题证据按需读取专题，不在此扩写。

<!-- proma:memory:start -->
## 记忆维护

- **个人层（常驻）**：[user_profile.md](</Users/Chester/.proma/memory/user_profile.md>)，跨项目共享，仅记录换个项目也成立的个人背景与稳定偏好。
- **项目护栏层（常驻）**：本文件（AGENTS.md，预算 ≤4000 非空白字符），仅保留不看就会在本项目犯错的子项目结构、常用命令与全局红线；结构或命令变化时就地更新，模块细节、排障经过和某日状态快照一律下沉到项目 memory/。
- **专题手册层（按需）**：[MEMORY.md](</Users/Chester/.proma/agent-workspaces/glmusage/memory/MEMORY.md>) 仅维护一行一条的场景路由索引（预算 ≤3500 字符，不写长篇结论摘要），详细主题按索引按需读取；历史部署、接口、签名与 UI 排障已下沉至 [operations-and-protocols.md](</Users/Chester/.proma/agent-workspaces/glmusage/memory/operations-and-protocols.md>)；过期或已合并的存量文件通过可恢复归档移出有效入口。读取不等于核验，不编造用户事实。
<!-- proma:memory:end -->
