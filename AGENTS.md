# AGENTS.md

## 工作区状态

GLM Coding Plan 用量菜单栏工具（对标 `~/Documents/kimi/workspace/kimi-usage-menubar` 的 KimiUsage），2026-09-26 建成 v1.0.0 并已部署。

## 构建与验证

```bash
./build.sh                                            # 编译 + 打包 + ad-hoc 签名（产物 GlmUsage.app）
./GlmUsage.app/Contents/MacOS/GlmUsage --once         # 命令行自检：拉一次数据打印后退出
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test    # 峰谷时段边界回归（改活动日期后必跑）
```

需要 macOS 13+ 和 Xcode CLT（`swiftc`）。部署方式：`cp -R GlmUsage.app ~/Applications/`，LaunchAgent `com.local.glm-usage` 负责启动（本机 `open`/Gatekeeper 拒绝 ad-hoc 应用，与 KimiUsage 相同，必须走 LaunchAgent 直接执行二进制）。

## 架构

单文件 `GlmUsage.swift`（AppKit 菜单栏应用，无外部依赖）：

- **CredStore**：只读解密 `~/.zcode/v2/credentials.json`（`enc:v1:` = AES-256-GCM，密钥 = SHA256(`ZCODE_CREDENTIAL_SECRET` 环境变量，未设则 `zcode-credential-fallback:darwin:<homedir>:<username>`），与 ZCode 客户端 zcode.cjs 逻辑一致；也可用 `GLM_API_KEY` 环境变量直供）。key 只存在内存，绝不写盘/入库。
- **Fetcher**：智谱监控接口（源自官方 zai-org/zai-coding-plugins 的 glm-plan-usage 插件），base `https://open.bigmodel.cn`：
  - `/api/monitor/usage/quota/limit` — 5 小时 + 7 天（周）credits（`CREDIT_LIMIT`，unit 3=小时/6=周；官方文档 docs.bigmodel.cn/cn/coding-plan/overview：Lite 2,000/5h + 10,000/周；旧版 TOKENS_LIMIT/TIME_LIMIT 已随 2026-07 积分制改版下线；`nextResetTime` 为 epoch 毫秒）
  - `/api/monitor/usage/model-usage?startTime=&endTime=` — 按小时 token/调用数（本地时区 `yyyy-MM-dd HH:mm:ss`）
  - `/api/monitor/usage/tool-usage` — MCP 工具次数
- **Peak**：峰谷时段本地计算，新版积分制口径（高峰=工作日 14:00–18:00 全价，其余时间+周末全天 5 折；Asia/Shanghai 时区，不依赖系统时区；老版 V1/V2 的 3倍/1倍 口径不适用）。限时活动硬编码日期、过期自动失效：双节 2026-09-25~10-07 全天 5 折；深夜错峰 2026-09-03~10-07 每日 23:00–09:00 ZCode 内 Flash 0 消耗/其他 Agent 额度×2。菜单栏标题 emoji（🔥 高峰 / ⚡ 深夜活动）+ 下拉菜单状态行；`--peak-test` 为边界回归用例，**改活动日期后必跑**。
- 刷新节奏：额度每 60s，token 统计每 5 分钟（`tokenEveryCycles`）。token 统计全靠服务端，不扫描本地会话日志（与 KimiUsage 的关键差异）。
- 自诊断写 `~/Library/Application Support/GlmUsage/status.json`。

## 约定

- 与用户（君晓）沟通用中文，保留英文技术术语。
- 用户是非程序员（HRBP / PM / Investor），解释技术决策时避免底层细节堆砌，直接给结论和可选项。
- 改代码后必须重新 `./build.sh` + `--once` 自检并报告结果；敏感信息（API key 等）不得出现在代码、提交或日志输出中。

## 修改本文件

工作区内容变化后（新增项目、引入构建工具），用 Edit 更新对应章节，不要整篇重写。
