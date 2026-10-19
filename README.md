# GlmUsage — GLM Coding Plan 余量菜单栏小工具

macOS 菜单栏常驻，一瞥即知智谱 GLM Coding Plan（即 ZCode 使用的订阅）的额度余量。原生 Swift 单文件实现，纯本地运行。

与 [KimiUsage](https://github.com/JUNX7764/kimi-usage-menubar)、[CodexUsage](https://github.com/JUNX7764/Codexusage) 是同族三件套，分别盯 Kimi / GLM / Codex 的订阅余量。

## 功能

- **菜单栏**：两行常驻，5H / 7D 剩余百分比
- **额度窗口**：5 小时 / 7 天剩余比例、剩余 credits、重置时间、套餐等级
- **Token 统计**：今天 / 近 7 天 / 近 30 天消耗与调用次数，按模型明细（服务端统计，无需扫描本地日志）
- **MCP 工具**：近 30 天网络搜索 / 网页读取次数
- **刷新机制**
  - 额度每 60 秒；token / MCP / 重置卡 / 套餐每 5 分钟（源码 `tokenEveryCycles` 可调）；定时器容差 6 秒
  - 额度窗口、各 token 时间窗、MCP、两类重置卡和套餐分别记录成功时间；字段缺失或非法时保留旧值并显示错误/过期状态
  - 并行请求合并经串行保护；同一时间最多一轮刷新，重叠手动刷新最多再补一轮完整刷新，定时刷新重叠丢弃

## 安装与构建

需要 macOS 13+ 与 Xcode Command Line Tools（未装先执行 `xcode-select --install`，自带 `swiftc`）：

```bash
./build.sh
```

产物 `GlmUsage.app`，拖到 `~/Applications` 或 `/Applications` 双击运行。首次打开如遇 Gatekeeper 提示，右键 → 打开。

## 原理

- **凭据**：只读 ZCode 本地加密凭证库 `~/.zcode/v2/credentials.json`（AES-256-GCM，密钥派生与 ZCode 客户端一致：环境变量 `ZCODE_CREDENTIAL_SECRET` 或 `zcode-credential-fallback:darwin:<homedir>:<username>`），内存中解出订阅 api-key，不落盘、不写入本仓库
- **接口**：智谱开放平台监控接口（与官方 glm-plan-usage 插件同源）
  - `GET https://open.bigmodel.cn/api/monitor/usage/quota/limit`
  - `GET https://open.bigmodel.cn/api/monitor/usage/model-usage?startTime=&endTime=`
  - `GET https://open.bigmodel.cn/api/monitor/usage/tool-usage?startTime=&endTime=`

## 隐私与安全

- 纯本地运行，凭据不离开本机
- 凭据只读解出 api-key，不落盘、不写入本仓库

## 调试与自检

```bash
# 离线自检：只用临时目录和离线假数据，不读 ZCode 凭据、不联网
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test

# 真实自检：读取本机凭据、联网拉一次数据后退出
./GlmUsage.app/Contents/MacOS/GlmUsage --once

# 无 ZCode 凭证库时可用环境变量提供 key
GLM_API_KEY=xxx ./GlmUsage.app/Contents/MacOS/GlmUsage --once
```

运行状态自诊断写入 `~/Library/Application Support/GlmUsage/status.json`。

## 文件说明

| 文件 | 说明 |
|---|---|
| `GlmUsage.swift` | 全部源码（单文件 AppKit 菜单栏应用） |
| `build.sh` | 编译 + 打包 + ad-hoc 签名脚本 |
| `Info.plist` | App Bundle 配置（LSUIElement = 菜单栏常驻） |
| `scripts/icon_gen.swift` | 图标生成脚本（缺 icns 时 build.sh 自动调用） |

## License

MIT
