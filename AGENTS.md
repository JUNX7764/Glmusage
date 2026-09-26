# AGENTS.md

## 工作区状态

GLM Coding Plan 用量菜单栏工具（对标 `~/Documents/kimi/workspace/kimi-usage-menubar` 的 KimiUsage），2026-09-26 建成 v1.0.0 并已部署。

## 构建与验证

```bash
./build.sh                                            # 编译 + 打包 + ad-hoc 签名（产物 GlmUsage.app）
./GlmUsage.app/Contents/MacOS/GlmUsage --once         # 命令行自检：拉一次数据打印后退出
```

需要 macOS 13+ 和 Xcode CLT（`swiftc`）。部署方式：`cp -R GlmUsage.app ~/Applications/`，LaunchAgent `com.local.glm-usage` 负责启动（本机 `open`/Gatekeeper 拒绝 ad-hoc 应用，与 KimiUsage 相同，必须走 LaunchAgent 直接执行二进制）。

## 架构

单文件 `GlmUsage.swift`（AppKit 菜单栏应用，无外部依赖）：

- **CredStore**：只读解密 `~/.zcode/v2/credentials.json`（`enc:v1:` = AES-256-GCM，密钥 = SHA256(`ZCODE_CREDENTIAL_SECRET` 环境变量，未设则 `zcode-credential-fallback:darwin:<homedir>:<username>`），与 ZCode 客户端 zcode.cjs 逻辑一致；也可用 `GLM_API_KEY` 环境变量直供）。key 只存在内存，绝不写盘/入库。
- **Fetcher**：智谱监控接口（源自官方 zai-org/zai-coding-plugins 的 glm-plan-usage 插件），base `https://open.bigmodel.cn`：
  - `/api/monitor/usage/quota/limit` — 5 小时窗口 + 月度 credits（`CREDIT_LIMIT`，unit 3=小时/6=月；旧版为 TOKENS_LIMIT/TIME_LIMIT；`nextResetTime` 为 epoch 毫秒）
  - `/api/monitor/usage/model-usage?startTime=&endTime=` — 按小时 token/调用数（本地时区 `yyyy-MM-dd HH:mm:ss`）
  - `/api/monitor/usage/tool-usage` — MCP 工具次数
- 刷新节奏：额度每 60s，token 统计每 5 分钟（`tokenEveryCycles`）。token 统计全靠服务端，不扫描本地会话日志（与 KimiUsage 的关键差异）。
- 自诊断写 `~/Library/Application Support/GlmUsage/status.json`。

## 约定

- 与用户（君晓）沟通用中文，保留英文技术术语。
- 用户是非程序员（HRBP / PM / Investor），解释技术决策时避免底层细节堆砌，直接给结论和可选项。
- 改代码后必须重新 `./build.sh` + `--once` 自检并报告结果；敏感信息（API key 等）不得出现在代码、提交或日志输出中。

## 修改本文件

工作区内容变化后（新增项目、引入构建工具），用 Edit 更新对应章节，不要整篇重写。
