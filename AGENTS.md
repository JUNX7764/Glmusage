# AGENTS.md

## 工作区状态

GLM Coding Plan 用量菜单栏工具（对标 `~/Documents/kimi/workspace/kimi-usage-menubar` 的 KimiUsage），2026-09-26 建成 v1.0.0 并已部署。

## 构建与验证

```bash
./build.sh                                            # 编译 + 打包 + ad-hoc 签名（产物 GlmUsage.app）
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test    # 离线回归：临时目录/假数据，不读凭据、不联网
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test    # 峰谷时段边界回归（改活动日期后必跑）
```

`--once` 是真实接口验收，会读取本机凭据并联网；仅在明确安排网络验收、且确认没有其他实例并发运行时执行。

**部署前必做 GUI 冒烟**：`--self-test`/`--once` 全是命令行路径，抓不住 GUI 启动期崩溃（如 2026-09-28 的 inout 独占访问 SIGABRT：同一调用里把 `usage` 结构体的两个子字段同时作 inout 实参）。部署前直接跑二进制 10 秒确认驻留且 status.json 更新：`./GlmUsage.app/Contents/MacOS/GlmUsage & sleep 10; pgrep -x GlmUsage`。另注意：同一调用不得对同一存储属性的两个子字段取 inout（Swift 独占访问运行时冲突），状态合并用纯函数返回结果再顺序赋值。

需要 macOS 13+ 和 Xcode CLT（`swiftc`）。部署方式：`cp -R GlmUsage.app ~/Applications/`，LaunchAgent `com.local.glm-usage` 负责启动（本机 `open`/Gatekeeper 拒绝 ad-hoc 应用，与 KimiUsage 相同，必须走 LaunchAgent 直接执行二进制）。`cp -R` 替换 .app 后先 `launchctl kickstart -k gui/$(id -u)/com.local.glm-usage`；若进程不驻留、`launchctl list` 显示退出码 78，需完整重载：`bootout` + `bootstrap`（三个 usage app 同理）。

## 架构

单文件 `GlmUsage.swift`（AppKit 菜单栏应用，无外部依赖）：

- **CredStore**：只读解密 `~/.zcode/v2/credentials.json`（`enc:v1:` = AES-256-GCM，密钥 = SHA256(`ZCODE_CREDENTIAL_SECRET` 环境变量，未设则 `zcode-credential-fallback:darwin:<homedir>:<username>`），与 ZCode 客户端 zcode.cjs 逻辑一致；也可用 `GLM_API_KEY` 环境变量直供）。key 只存在内存，绝不写盘/入库。
- **Fetcher**：智谱监控接口（源自官方 zai-org/zai-coding-plugins 的 glm-plan-usage 插件），base `https://open.bigmodel.cn`：
  - `/api/monitor/usage/quota/limit` — 5 小时 + 7 天（周）credits（`CREDIT_LIMIT`，unit 3=小时/6=周；官方文档 docs.bigmodel.cn/cn/coding-plan/overview：Lite 2,000/5h + 10,000/周；旧版 TOKENS_LIMIT/TIME_LIMIT 已随 2026-07 积分制改版下线；`nextResetTime` 为 epoch 毫秒）
  - `/api/monitor/usage/model-usage?startTime=&endTime=` — 按小时 token/调用数（本地时区 `yyyy-MM-dd HH:mm:ss`）
  - `/api/monitor/usage/tool-usage` — MCP 工具次数
  - `/api/biz/subscription/list` — 套餐信息（`status=="VALID"` 首条的 `productName` + `valid` 末尾到期时间），Bearer API key 认证，code==200
- **充值卡（额度重置卡）**：`GET https://zcode.z.ai/api/v1/coding-plan/reset/status`（注意：ZCode 自家后端，非 open.bigmodel.cn；成功码 code==0）。需双 token 认证：`Authorization: Bearer <zcodejwttoken>` + `X-Bigmodel-Authorization: <oauth:bigmodel:access_token>` + `Bigmodel-Target-Type: PERSONAL`，两 token 均在 credentials.json（`CredStore.loadResetTokens()` 解密）。响应 `available_five_hour_resets`/`available_week_resets` 数组、每张卡 `expire_at` 为 epoch 毫秒。接口路径逆向自 ZCode app.asar（`/use` `/opportunity` `/history/read` 均为写操作，应用只读 status，绝不自动用卡）。token 是 ZCode 登录态、可能过期 → 失败时菜单降级为提示行。
- **Peak**：峰谷时段本地计算，新版积分制口径（高峰=工作日 14:00–18:00 全价，其余时间+周末全天 5 折；Asia/Shanghai 时区，不依赖系统时区；老版 V1/V2 的 3倍/1倍 口径不适用）。限时活动硬编码日期、过期自动失效：双节 2026-09-25~10-07 全天 5 折；深夜错峰 2026-09-03~10-07 每日 23:00–09:00 ZCode 内 Flash 0 消耗/其他 Agent 额度×2。菜单栏标题 emoji（🔥 高峰 / ⚡ 深夜活动）+ 下拉菜单状态行；`--peak-test` 为边界回归用例，**改活动日期后必跑**。
- 刷新节奏：额度每 60s，token 统计/MCP/充值卡/套餐到期每 5 分钟（`tokenEveryCycles`）；Timer 容差 6s。额度窗口、各 token 时间窗、MCP、两类充值卡和套餐分别记最后成功时间，失败保留旧值并显示错误/过期状态。最多一轮刷新；重叠手动刷新合并为一轮后续完整刷新，定时重叠不排队。token 统计全靠服务端，不扫描本地会话日志（与 KimiUsage 的关键差异）。
- 自诊断写 `~/Library/Application Support/GlmUsage/status.json`。

## 约定

- 与用户（君晓）沟通用中文，保留英文技术术语。
- 用户是非程序员（HRBP / PM / Investor），解释技术决策时避免底层细节堆砌，直接给结论和可选项。
- 改代码后必须重新 `./build.sh` + `--self-test` + `--peak-test` 并报告结果。`--once` 属于真实凭据/网络验收，不作为离线回归步骤；敏感信息（API key 等）不得出现在代码、提交或日志输出中。

## 修改本文件

工作区内容变化后（新增项目、引入构建工具），用 Edit 更新对应章节，不要整篇重写。
