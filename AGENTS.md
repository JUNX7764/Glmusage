# AGENTS.md

## 项目与入口

GlmUsage 是 macOS 13+、Apple Silicon 的 GLM Coding Plan 原生 AppKit 菜单栏应用，无第三方包依赖。Bundle / LaunchAgent：`com.local.glm-usage`；产物 `GlmUsage.app`。

| 入口 | 职责 |
|---|---|
| `GlmUsage.swift` | CredStore、Fetcher、Peak、更新、AppDelegate 与原生面板组装、离线自检 |
| `Sources/GLMQuotaCycleHistory.swift` | 周额度观测、状态机、浏览与详情语义 |
| `Sources/GLMQuotaCycleContext.swift` | 套餐连接分区与用卡归属判定 |
| `Sources/GLMQuotaCycleStore.swift` / `GLMQuotaCycleCoordinator.swift` | 版本化私有存储与串行协调 |
| `Sources/GLMQuotaCycleHistoryView.swift` | 原生额度周期图与交互 |
| `build.sh`、`scripts/update.sh`、`scripts/release.sh` | 本地打包、就地更新、发布 |
| `tests/` | PATH mock 脚本回归与独立 Swift 历史夹具 |

用户说明从 `README.md` 进入；当前工程事实见 `docs/DEVELOPMENT.md`，架构/标准/发布见 `docs/project/02-architecture.md`、`07-standards.md`、`10-release.md`，额度历史见 `17-quota-cycle-history.md`。判断行为优先源码与测试，不能把计划、旧文档或历史快照当作已实现规格。

## 构建与验证

需要 Xcode CLT 和 macOS 26+ SDK；部署目标为 macOS 13、arm64。多文件编译由 build.sh 临时复制主文件为 main.swift，显式列出 Sources；不要丢失 top-level 入口或擅自改成全目录通配符。签名优先本机稳定 `local-codesign`，不存在回退 ad-hoc，不为普通开发修改证书或系统信任。

```bash
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test
python3 -m unittest discover -s tests -p '*_test.py' -v
bash -n build.sh scripts/update.sh scripts/release.sh
codesign --verify --deep --strict GlmUsage.app
```

改代码后必须重新构建并跑 self-test、peak-test 和相关回归，报告实际结果。`--once` 会读真实凭据并联网，只有明确安排网络验收且确认无其他实例并发时才运行，不能混入离线测试。

原生假数据交互入口：

```bash
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-popover-test
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-connection-test
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-daily-test --preview-daily-gaps
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-popover --preview-quota-history --preview-quota-history-test
```

GUI 测试逐个运行、退出后间隔≥5s，键盘测试须屏幕解锁且取得 key window；拿不到焦点不得报通过。CLI/固定数据截图不替代真实 AppKit 交互。部署前仍须实际 GUI 驻留约10秒并确认本次 PID 与诊断更新，避免漏掉启动崩溃。不得同一调用对同一存储属性的两个子字段同时取 inout；用纯函数返回后顺序赋值。

## 跨任务红线

- 与用户用中文，技术细节按需展开；源代码职责轻量分层，不向主文件继续堆叠新业务算法。
- 凭据文件只读；启动/后台钥匙串读取 non-interactive，不自动弹授权框，交互解锁仅由用户点击修复/连接设置触发。Key、token、认证头、原幂等 key 不进代码、提交、日志或诊断状态。preview/自检使用假数据、临时根，不读真实凭据/pending/history，不初始化真实历史仓库。
- 手动套餐 API Key 与 ZCode 登录态/邮箱不一定同账号。历史 API Key 按连接隔离、更换 Key 不自动合并；OAuth 回退仅本进程记录，未证实同身份的用卡不得标主动重置。
- 额度独立10s刷新，慢项5min，手动全量；失败保留旧值与原成功时间。历史只收本次有效无 warning 的 fresh.week，不拿合并缓存当新样本，不从 Token/赠送用量反推积分，不补假周期或漏周零柱。
- 重置卡消费仅用户点击并二次确认，preview禁用，绝不自动触发；成功严格 code==0 且 data.used==true；结果未知复用原幂等 key，成功后保留既有3秒补刷。5小时卡不能结束周额度历史。
- Peak 固定 Asia/Shanghai，高峰工作日14:00–18:00全价、其余/周末5折；修改活动日期必跑 peak-test，不二次对接口积分打折。
- 重要系统配置、凭据写入、真实用卡、安装/重载、公开发布与危险 Git 操作须获相应授权。不得混淆 worktree 构建与用户已安装 App，不结束用户生产进程。update.sh 只处理目标 tag 和目标 App 路径，检测其他运行副本安全中止。
- 多个usage app部署/重载须错开≥5s，避免菜单栏图标叠位；KeepAlive 使用 SuccessfulExit=false，正常退出不保活、崩溃保活有节流。具体操作与旧问题证据按需读取专题，不在此扩写。

## 记忆维护

- 个人层：[user_profile.md](</Users/Chester/.proma/memory/user_profile.md>) 只保存跨项目稳定背景与偏好。
- 护栏层：本文件≤4000非空白字符，只保留全局入口、真实命令与红线；结构或命令变化时就地更新，模块 SOP 不继续追加。
- 专题层：[MEMORY.md](</Users/Chester/.proma/agent-workspaces/glmusage/memory/MEMORY.md>) 仅作≤3500字符的一行场景路由，详情按需读 `memory/*.md`。历史部署、接口、签名与UI排障已下沉至 [operations-and-protocols.md](</Users/Chester/.proma/agent-workspaces/glmusage/memory/operations-and-protocols.md>)，读取不等于本轮重新核验；新增主题同步索引，过期内容核实后可恢复归档，不编造事实。
