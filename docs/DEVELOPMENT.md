# GlmUsage 开发与维护

> **当前工程事实源**。构建、测试、发布、接口或权限行为变化时，应在同一个提交中更新本文。
> 最后核对：2026-11-12。

## 文档入口与效力

| 文档 | 用途 |
|---|---|
| `README.md` | 面向用户的功能、安装、更新与隐私说明 |
| `docs/DEVELOPMENT.md` | 当前构建、测试、发布和验证边界 |
| `docs/project/02-architecture.md` | 当前模块、数据流和信任边界 |
| `docs/project/07-standards.md` | 当前维护与测试约定 |
| `docs/project/10-release.md` | 当前发布资产、门禁和回滚边界 |
| `AGENTS.md` | 本机协作约定与已验证的运维经验 |

判断当前行为时，优先级为：**源码与测试 → 当前工程文档 → README 与历史运维记录**。不得用空模板或历史发布记录证明现状。

## 构建

运行需要 macOS 13 或更新版本及 Apple Silicon；构建需要 macOS 26 或更新的 SDK 和 Xcode Command Line Tools；未安装 CLT 时先执行 `xcode-select --install`。

```bash
./build.sh
```

`build.sh` 重建项目内的 `GlmUsage.app`，优先使用本机 `local-codesign` 身份，缺失时回退 ad-hoc，再验证签名。脚本复制入口到临时 `main.swift`，与 `Sources/` 中的周期回顾模块一起编译；临时目录由脚本清理。

## 原理与数据边界

- **凭据**：优先使用 `GLM_API_KEY`，其次使用用户在 GlmUsage 面板中连接的套餐 API Key，最后回退到 ZCode `~/.zcode/v2/credentials.json` 中支持的凭据。`enc:v1` 可使用 `ZCODE_CREDENTIAL_SECRET` 参与密钥派生；`enc:v2:os` 依赖系统钥匙串授权，`enc:v2:env` 不支持。用户主动连接时先查询额度验证，成功后存入 GlmUsage 的 macOS 钥匙串条目。重置卡使用 ZCode 双 token；可读取已授权的 `enc:v2:os` 登录态。API Key 与 OAuth token 不写入仓库、日志或诊断状态。
- **连接入口**：底部不再显示「套餐设置」，顶部「GLM 用量」是无边框、可键盘访问的连接设置入口，悬停提供提示。已知凭据缺失/格式不支持、HTTP 401/403 或钥匙串未授权时显示「修复连接」；锁定优先解锁对应来源，其他凭据问题进入备用设置，HTTP 5xx/超时继续自动重试而不引导填 Key。启动不再在1.5秒后主动调用交互式解锁；启动与定时刷新仅non-interactive读取，系统授权仅由用户显式点击触发，既有已保存来源不自动删除或切换。
- **额度与用量**：通过智谱监控接口查询 5 小时、7 天额度、模型 Token / 调用数和 MCP 工具次数。
- **额度周期回顾**：只采集独立额度刷新通道中无警告、带有效 reset 的新鲜周额度；周期、证据、连接分区和存储边界见 `docs/project/17-quota-cycle-history.md`。
- **Start Plan 用量**：只读 `~/.zcode/cli/db/db.sqlite` 的 `model_usage`，按请求时间将国内 Start Plan 的 Token 与调用数补入今天、近 7 天、近 30 天、模型明细和每日趋势。同名模型忽略大小写合并，保留官方显示名。使用 `provider_total_tokens`，缺失时回退 `computed_total_tokens`，缓存输入已计入总数；仅纳入已结束且 Token 大于零的请求，实际重试的额外消耗保留。使用系统 SQLite3，无第三方依赖。
- **补统计边界**：赠送余额接口只提供额度桶累计值，不能用于拆分历史周期。补统计覆盖本机已记录的请求，其他设备的赠送用量不可得。缺少数据库或旧版无请求表时沿用服务端统计；现有表读取失败则保留上次完整合并值并提示待更新。手动连接或环境变量提供 API Key 时使用该 Key 的服务端统计，避免混入其他 ZCode 账号的本机用量。预览与自检使用假数据。
- **订阅**：通过 `/api/biz/subscription/list` 获取有效套餐与到期时间；明确无有效订阅时清除旧套餐数据，普通失败保留旧值并提示。
- **重置卡**：通过 ZCode `/api/v1/coding-plan/reset/status` 查询 5 小时卡和周卡。手动使用走 `/reset/use`，必须由用户点击并二次确认；结果未知时按卡类型复用原幂等 key，禁止生成新请求盲目重试。
- **Peak**：按 Asia/Shanghai 计算工作日高峰、周末和活动时段。活动日期修改后必须运行 `--peak-test`。
- **刷新**：额度每 10 秒，慢项每 5 分钟；失败保留旧值与原成功时间，并显示错误或过期状态。

凭据保存在本机，但查询智谱／ZCode 时会作为必要认证信息发送给对应服务；不会上传到开发者自有服务器。更新检查会连接 GitHub。应用只读取 ZCode 凭据，不修改凭据文件。

面板连接和环境变量 `GLM_API_KEY` 均使用[个人或团队编程套餐对应的 API Key](https://docs.bigmodel.cn/cn/coding-plan/extension/coding-tool-helper)。`GLM_API_KEY` 由 GlmUsage 启动进程的环境提供。面板连接使用本机钥匙串，钥匙串要求重新授权时可在面板重新连接。

## 调试与自检

```bash
# 离线自检：临时目录和假数据，不读真实 ZCode 凭据、不联网
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test

# 峰谷时段与活动日期边界回归
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test

# 脚本回归：PATH mock，不操作真实 app、LaunchAgent 或 GitHub
python3 -m unittest discover -s tests -p '*_test.py'

# Shell 语法检查
bash -n build.sh scripts/update.sh scripts/release.sh

# 连接入口：标题/底部隐藏/异常路由/原生弹窗与取消结果（控件激活，非硬件鼠标；所有数据为假）
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-connection-test
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-connection-test --preview-narrow

# 原生 Popover 假数据交互回归（与其他GUI进程错开至少5秒）
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-popover-test

# 每日用量交互回归（悬停/键盘/Tab 可达/零日缺失读取；与上一条错开 ≥5s 逐个跑）
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-daily-test --preview-daily-gaps

# 周额度回顾：隔离假数据预览与事件回归（两次 GUI 运行至少间隔 5 秒）
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-quota-history
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-popover --preview-quota-history --preview-quota-history-test

# 可附加 --preview-dark / --preview-narrow；状态用 --preview-quota-history-state=empty|short|long|unsaved|volatile|protected
# 每日图空态/缺口/基期0/数据不足变体（与 --preview-daily-test 错开 ≥5s 逐个跑）
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-daily-unavailable
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-daily-basezero
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-daily-insufficient

# 更新流程预览（进度行原位展示；不执行真实更新）
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-updating
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-updating-install

# 峰谷卡高峰状态视觉回归：配合 --preview-screenshot 截图，强制按高峰时刻渲染
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-peak --preview-screenshot /tmp/glm_peak.png

# 真实自检：读取本机凭据并联网，不属于离线测试
./GlmUsage.app/Contents/MacOS/GlmUsage --once
```

无 ZCode 凭证库时，可在真实网络验收中通过 `GLM_API_KEY` 提供 key；不得把真实 key 写入命令记录、文档或提交。运行状态诊断写入 `~/Library/Application Support/GlmUsage/status.json`。

## 文件说明

| 文件 | 说明 |
|---|---|
| `GlmUsage.swift` | AppKit 入口、凭据、网络、原面板与事件接线 |
| `Sources/GLMQuotaCycle*.swift` | 周额度历史的模型、上下文、存储、协调器与原生视图 |
| `tests/quota_cycle_history_test.py` | 假数据与临时目录中的周额度历史测试 |
| `build.sh` | 多文件编译、打包和签名验证 |
| `Info.plist` | Bundle 身份、最低系统版本和菜单栏常驻配置 |
| `scripts/icon_gen.swift` | 图标生成脚本 |
| `scripts/update.sh` | Release 下载、校验、暂存、换包和失败回滚 |
| `scripts/release.sh` | 标签、构建、自检、Peak 测试、资产校验和 Release 发布 |
| `tests/script_test.py` | 更新、发布和签名故障的离线回归测试 |

## 发布前必须执行

```bash
git status --short
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test
python3 -m unittest discover -s tests -p '*_test.py'
bash -n build.sh scripts/update.sh scripts/release.sh
```

确认工作区干净且 HEAD 已推送后，再运行 `scripts/release.sh v1.2.3`。

`release.sh` 会执行构建、二进制自检、Peak 测试、签名和资产校验，但**不会自动运行 Python 脚本回归，也不代表真实面板更新、回滚或最低系统版本验收已完成**。完整要求见 `docs/project/10-release.md`。

## 验证证据边界

- 离线自检、Peak 测试和 PATH mock 不能替代真实凭据、智谱／ZCode 接口、LaunchAgent 或安装目录权限验证。
- `--once` 会读取真实登录态并联网，只能在明确安排网络验收时执行。
- macOS 13 部署目标不等同于已在 macOS 13、14、15 或干净用户环境完成实机验收。
- 真实更新验收必须记录旧版版本、目标版本、安装路径、是否从面板点击，以及重启和回滚结果。

面板背景默认纯色；液态玻璃需 macOS 26+，旧系统回退经典毛玻璃，系统开启降低透明度时显示纯色。`--preview --preview-background=solid|classicMaterial|liquidGlass` 可使用假数据预览；`--preview --preview-update-notes` 预览更新确认，不执行真实更新。版本说明来自所选可安装 Release，确认前不下载。

手动套餐连接时，如 ZCode 登录资料可在后台读取且含有效邮箱，标题直接显示该邮箱；此邮箱不证明与套餐 API Key 属于同一账号。读取失败时隐藏，不保留该来源的旧邮箱；不新增网络请求。
