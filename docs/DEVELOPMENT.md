# GlmUsage 开发与维护

> **当前工程事实源**。构建、测试、发布、接口或权限行为变化时，应在同一个提交中更新本文。
> 最后核对：2026-11-06。

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

需要 macOS 13 或更新版本、Apple Silicon 和 Xcode Command Line Tools；未安装 CLT 时先执行 `xcode-select --install`。

```bash
./build.sh
```

`build.sh` 会重建项目内的 `GlmUsage.app` 并执行 ad-hoc 签名验证。拆分源码时必须保留合法 top-level 入口并同步调整构建脚本。

## 原理与数据边界

- **凭据**：只读解密 ZCode `~/.zcode/v2/credentials.json`。可使用环境变量 `ZCODE_CREDENTIAL_SECRET` 参与密钥派生，或用 `GLM_API_KEY` 直接提供 key。API key 与 OAuth token 只在必要内存中使用，不写入仓库、日志或诊断状态。
- **额度与用量**：通过智谱监控接口查询 5 小时、7 天额度、模型 Token / 调用数和 MCP 工具次数。
- **订阅**：通过 `/api/biz/subscription/list` 获取有效套餐与到期时间；明确无有效订阅时清除旧套餐数据，普通失败保留旧值并提示。
- **重置卡**：通过 ZCode `/api/v1/coding-plan/reset/status` 查询 5 小时卡和周卡。手动使用走 `/reset/use`，必须由用户点击并二次确认；结果未知时按卡类型复用原幂等 key，禁止生成新请求盲目重试。
- **Peak**：按 Asia/Shanghai 计算工作日高峰、周末和活动时段。活动日期修改后必须运行 `--peak-test`。
- **刷新**：额度每 10 秒，慢项每 5 分钟；失败保留旧值与原成功时间，并显示错误或过期状态。

凭据保存在本机，但查询智谱／ZCode 时会作为必要认证信息发送给对应服务；不会上传到开发者自有服务器。更新检查会连接 GitHub。应用只读取 ZCode 凭据，不修改凭据文件。

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

# 原生 Popover 假数据交互回归
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-popover-test

# 真实自检：读取本机凭据并联网，不属于离线测试
./GlmUsage.app/Contents/MacOS/GlmUsage --once
```

无 ZCode 凭证库时，可在真实网络验收中通过 `GLM_API_KEY` 提供 key；不得把真实 key 写入命令记录、文档或提交。运行状态诊断写入 `~/Library/Application Support/GlmUsage/status.json`。

## 文件说明

| 文件 | 说明 |
|---|---|
| `GlmUsage.swift` | 当前全部 Swift 源码；单文件 AppKit 菜单栏应用 |
| `build.sh` | 编译、打包和 ad-hoc 签名 |
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
