# GlmUsage

**GLM Coding Plan 的剩余额度和使用情况，抬眼就能看到。**

不用反复打开网页，在 Mac 菜单栏查看还剩多少、什么时候恢复，用量面板一点即开。

**[下载 GlmUsage](https://github.com/JUNX7764/Glmusage/releases/latest)** · macOS 13 或更高版本 · Apple Silicon


**本地运行，直接查询智谱用量。**

<img src="docs/images/glm-usage-preview.png" alt="GlmUsage 用量面板，展示剩余额度、重置时间、重置卡和用量统计" width="370">

<sub>界面展示使用示例数据。</sub>

## 能做什么

- **看剩余额度**：菜单栏显示 5 小时和 7 天的剩余比例；点开查看剩余积分和重置时间。
- **看使用情况**：查看今天、近 7 天和近 30 天的 Token 用量及调用次数，并可展开模型明细。
- **看重置卡**：查看可用的 5 小时卡和周卡及其到期时间，不会自动使用。
- **看工具和时段**：查看网络搜索、网页读取次数，以及当前峰谷时段提示。
- **留意数据是否过期**：刷新失败时保留上次结果，并在界面提示错误或数据过期。

Token 与工具用量来自服务端统计。重置卡信息需要有效的 ZCode 登录状态。

## 安装

1. 建议先在 Mac 上安装并登录 ZCode，确保账号有 GLM Coding Plan；也可使用 API key，详见开发者说明。
2. 前往 [下载页面](https://github.com/JUNX7764/Glmusage/releases/latest)，下载 `GlmUsage.dmg`。
3. 打开安装包，将 GlmUsage 拖入「应用程序」文件夹，再打开应用。图标会出现在屏幕顶部菜单栏。

如果首次打开时 macOS 显示安全提示，可在 Finder 中右键点击 GlmUsage，选择「打开」并按提示操作。应用目前使用 ad-hoc 签名。

## 更新

有新版本时，菜单中会出现更新提示。点击后可在应用内查看更新进度，完成后自动重启。**从旧版首次升级到支持进度窗口的版本时，仍会出现终端窗口。**

## 数据与隐私

**应用在 Mac 本地运行，不会把用量数据上传到开发者服务器。**

额度和用量由智谱或 ZCode 服务提供，查询时会发送必要的认证信息；检查更新会连接 GitHub。应用只读取 ZCode 凭据，不修改凭据文件。

## 其他工具

[CodexUsage](https://github.com/JUNX7764/Codexusage) · [KimiUsage](https://github.com/JUNX7764/kimi-usage-menubar)

[开发者说明](docs/DEVELOPMENT.md) · [MIT License](LICENSE)
