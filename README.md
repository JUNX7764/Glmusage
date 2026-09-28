# GlmUsage — GLM Coding Plan 用量菜单栏小工具

一个 macOS 菜单栏（Menu Bar）小工具，实时显示智谱 GLM Coding Plan 订阅（即 ZCode 使用的订阅）的用量情况。结构与 KimiUsage 一致。

## 功能

- **额度窗口**：5 小时窗口 / 7 天额度的剩余比例、剩余 credits、重置时间、套餐等级
- **Token 统计**：今天 / 近 7 天 / 近 30 天的 token 消耗与调用次数、按模型明细（服务端统计，无需扫描本地日志）
- **MCP 工具**：近 30 天网络搜索 / 网页读取次数
- 菜单栏常驻两行显示（5H / 7D 剩余百分比），纯本地运行，凭据不离开本机

## 原理

- 凭据：只读 ZCode 本地加密凭证库 `~/.zcode/v2/credentials.json`（AES-256-GCM，密钥派生与 ZCode 客户端一致：环境变量 `ZCODE_CREDENTIAL_SECRET` 或 `zcode-credential-fallback:darwin:<homedir>:<username>`），在内存中解出订阅 api-key，不落盘、不写入本仓库
- 接口：智谱开放平台监控接口（与官方 glm-plan-usage 插件同源）
  - `GET https://open.bigmodel.cn/api/monitor/usage/quota/limit`
  - `GET https://open.bigmodel.cn/api/monitor/usage/model-usage?startTime=&endTime=`
  - `GET https://open.bigmodel.cn/api/monitor/usage/tool-usage?startTime=&endTime=`
- 刷新：额度每 60s；token/MCP/充值卡/套餐每 5 分钟（可在源码 `tokenEveryCycles` 调整）；定时器容差 6s
- 额度窗口、各 token 时间窗、MCP、两类充值卡和套餐分别记录成功时间；字段缺失或非法时保留旧值并显示错误/过期状态
- 并行请求合并经过串行保护；同一时间最多一轮刷新，重叠手动刷新最多再补一轮完整刷新，定时刷新重叠会丢弃

## 构建

需要 macOS 13+ 和 Xcode Command Line Tools（自带 `swiftc`）：

```bash
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test
```

`--self-test` 只使用临时目录和离线假数据，不读取 ZCode 凭据、不访问网络。真实接口检查仍可用 `--once`，但它会读取本机凭据并联网。

产物为 `GlmUsage.app`，拖到 `~/Applications` 或 `/Applications` 即可运行。首次打开如遇 Gatekeeper 提示，右键 → 打开。

## 调试

```bash
# 命令行自检：拉一次数据打印后退出
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
