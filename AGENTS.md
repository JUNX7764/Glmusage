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

需要 macOS 13+ 和 Xcode CLT（`swiftc`）。部署方式：`cp -R GlmUsage.app ~/Applications/`，LaunchAgent `com.local.glm-usage` 负责开机自启与崩溃保活（`cp -R` 替换 .app 后先 `launchctl kickstart -k gui/$(id -u)/com.local.glm-usage`；若进程不驻留、`launchctl list` 显示退出码 78，需完整重载：`bootout` + `bootstrap`，三个 usage app 同理，且错开 ≥5s 逐个重载）。

**双击/open 启动有效（2026-10-19 实测更正旧结论）**：本地构建 + `cp -R` 部署的 app 无 quarantine 标记，Finder 双击与 `open` 均可正常启动（spctl 虽显示 rejected，但 Gatekeeper 只强制拦截带 quarantine 的文件）。旧记录「open/Gatekeeper 拒绝 ad-hoc 应用」不成立于当前系统。退出后的恢复方式（按用户友好度排序）：双击 `~/Applications/GlmUsage.app`、`launchctl kickstart gui/$(id -u)/com.local.glm-usage`、重启电脑。注意：一旦 app 经由下载/解压等带 quarantine 的渠道分发，双击会被拦，须 `xattr -d com.apple.quarantine` 或走系统设置「仍要打开」；本仓库工作流（本地构建直拷）不受影响。

**KeepAlive 语义（2026-10-19 起，三个 usage app 同款）**：plist 与 app 内「开机自启」模板（`onToggleLogin`）均为 `KeepAlive={SuccessfulExit=false}`——菜单「退出」走 exit 0 真退出、launchd 不复活；崩溃/被 kill 仍自动拉起（launchd 默认 10s 节流，kill -9 后 10 秒内别误判为保护失效）；开机自启（RunAtLoad）不变。退出后手动恢复：`launchctl kickstart gui/$(id -u)/com.local.glm-usage`。

**菜单栏图标叠死坑（2026-10-19）**：多个 usage app 同一时刻被 launchd 拉起会竞态注册 NSStatusItem，图标落同一坐标（Glm/Kimi 均曾为 x=1354）互相盖住。重载/部署三个 app 时错开 ≥5s 逐个 `bootout`+`bootstrap`。验证坐标：`osascript -e 'tell application "System Events" to tell process "GlmUsage" to get position of menu bar item 1 of menu bar 1'`（三个 x 值必须互不相同）。

## 架构

单文件 `GlmUsage.swift`（AppKit 菜单栏应用，无外部依赖）：

- **CredStore**：优先使用 `GLM_API_KEY`，其次使用用户主动连接、验证通过并保存在 GlmUsage 钥匙串条目中的套餐 API Key。两者都没有时，只读解密 `~/.zcode/v2/credentials.json` 的旧版 `enc:v1` 凭据。没有旧版套餐 API Key 候选时使用旧版 `oauth:bigmodel:access_token`。ZCode 3.18.0 的新版登录用户可在 GlmUsage 里连接套餐，重置卡继续在 ZCode 管理。API Key 不写入日志或诊断状态。
- **Fetcher**：智谱监控接口（源自官方 zai-org/zai-coding-plugins 的 glm-plan-usage 插件），base `https://open.bigmodel.cn`：
  - `/api/monitor/usage/quota/limit` — 5 小时 + 7 天（周）credits（`CREDIT_LIMIT`，unit 3=小时/6=周；官方文档 docs.bigmodel.cn/cn/coding-plan/overview：Lite 2,000/5h + 10,000/周；旧版 TOKENS_LIMIT/TIME_LIMIT 已随 2026-07 积分制改版下线；`nextResetTime` 为 epoch 毫秒）
  - `/api/monitor/usage/model-usage?startTime=&endTime=` — 按小时 token/调用数（本地时区 `yyyy-MM-dd HH:mm:ss`）
  - `/api/monitor/usage/tool-usage` — MCP 工具次数
  - `/api/biz/subscription/list` — 套餐信息（`status=="VALID"` 首条的 `productName` + `valid` 末尾到期时间），Bearer API key 认证，code==200
- **重置卡**（官方名：额度重置卡）：`GET https://zcode.z.ai/api/v1/coding-plan/reset/status`（注意：ZCode 自家后端，非 open.bigmodel.cn；成功码 code==0）。需双 token 认证：`Authorization: Bearer <zcodejwttoken>` + `X-Bigmodel-Authorization: <oauth:bigmodel:access_token>` + `Bigmodel-Target-Type: PERSONAL`，两 token 均在 credentials.json（`CredStore.loadResetCredential()` 读取旧版凭据）。响应 `available_five_hour_resets`/`available_week_resets` 数组、每张卡 `expire_at` 为 epoch 毫秒。接口路径逆向自 ZCode app.asar。**支持手动用卡**（PR #3，2026-11-04 合并）：`POST /api/v1/coding-plan/reset/use`，body `{idempotency_key, reset_type: FIVE_HOUR|WEEK}`，成功 = `code==0 && data.used==true`；入口为面板「🎫 使用重置卡」按钮与下拉菜单项，仅用户点击 + 二次确认触发、绝不自动执行、预览模式禁用；结果未知（网络/5xx）时按类型复用同一幂等 key 防重复扣卡；成功后 3 秒补刷一次额度（服务端反映新窗口有秒级延迟）。token 是 ZCode 登录态、可能过期 → 失败时菜单降级为提示行。
- **Peak**：峰谷时段本地计算，新版积分制口径（高峰=工作日 14:00–18:00 全价，其余时间+周末全天 5 折；Asia/Shanghai 时区，不依赖系统时区；老版 V1/V2 的 3倍/1倍 口径不适用）。限时活动硬编码日期、过期自动失效：双节 2026-09-25~10-07 全天 5 折；深夜错峰 2026-09-03~10-07 每日 23:00–09:00 ZCode 内 Flash 0 消耗/其他 Agent 额度×2。菜单栏标题 emoji（🔥 高峰 / ⚡ 深夜活动）+ 下拉菜单状态行；`--peak-test` 为边界回归用例，**改活动日期后必跑**。
- 刷新节奏：额度每 10s，慢项每 5 分钟（30 个周期）；额度与慢项独立刷新，手动刷新全量。失败保留旧值，套餐明确无有效订阅时清除旧数据。
- 自诊断写 `~/Library/Application Support/GlmUsage/status.json`。

## 约定

- 与用户（君晓）沟通用中文，保留英文技术术语。
- 用户是非程序员（HRBP / PM / Investor），解释技术决策时避免底层细节堆砌，直接给结论和可选项。
- 改代码后必须重新 `./build.sh` + `--self-test` + `--peak-test` 并报告结果。`--once` 属于真实凭据/网络验收，不作为离线回归步骤；敏感信息（API key 等）不得出现在代码、提交或日志输出中。
- 用户说明以 `README.md` 为入口；当前构建、测试、发布和权限边界见 `docs/DEVELOPMENT.md`，架构、维护与发布约定见 `docs/project/`。判断当前行为须核对源码与测试，不使用空模板或历史记录代替当前规格。

## 修改本文件

工作区内容变化后（新增项目、引入构建工具），用 Edit 更新对应章节，不要整篇重写。

- 就地更新脚本接口：`update.sh <目标 tag> <当前 app 路径>`；仅处理目标副本，严格验证目标版本及实际加载的 LaunchAgent，检测其他运行副本时安全中止。离线脚本回归运行 `python3 -m unittest tests/script_test.py`。
- 更新进度在面板内原位展示（更新按钮变进度行，不弹独立窗口、不抢占焦点）：`UpdateProgressController` 为可订阅状态机，`Process` + `nohup` 直启子进程保留 TCC 责任应用归属（不要改回 `launchctl submit` 裸 shell：责任进程变成 `/bin/bash` 会导致换包 `mv` 被 `Operation not permitted` 拒绝）；关闭面板不中断更新，重开按状态恢复进度行；失败保留 alert 与 `usage-update-*/log` 日志兜底。预览参数：`--preview-updating`（下载中 62%）、`--preview-updating-install`（安装重启阶段）。
- 每日用量离线回归（2026-11-06 起）：`--preview-daily-test --preview-daily-gaps` 走真实事件派发验证悬停整天宽命中/缺失与零日读取/离开保留选中/点击选日/键盘←→/Tab 可达（key view loop 已显式接线）；`--preview-daily-unavailable`（Gate 未确认空态）、`--preview-daily-gaps/-basezero/-insufficient`（缺口/基期0/数据不足）。注意：`--preview-popover-test` 与 `--preview-daily-test` 背靠背启动会因菜单栏图标注册竞态污染几何断言，必须错开 ≥5s 逐个跑；`--preview-daily-test` 的键盘断言要求 popover 拿到 key window——**屏幕锁定时必然失败**（agent app 在锁屏下拿不到 key，2026-11-07 实测），须在解锁状态运行（测试入口已加 key 门控并写结果 sidecar `/tmp/glm_daily_test_result.txt`）。
- 峰谷卡（2026-11-08 起）为两行「极简状态条」：标题+状态胶囊 / 折扣+下次切换时间；展示数据走 `Peak.display(at:)`（与 `evaluate` 共用判定与时间措辞，`evaluate` 输出与 `--peak-test` 断言保持逐字节一致）。视觉回归用 `--preview --preview-peak --preview-screenshot <path>` 强制按高峰时刻渲染；卡片高度由内容撑出（非高峰/高峰两态均为 76.5pt），调整行距或字号后须对比截图确认两态高度一致。
- 菜单栏图标（2026-11-10 起）：5H/7D 两行正文对齐不变，峰谷/过期 badge（🔥/⚠️，墨迹高 12pt）不再钉在 5H 行而是垂直居中挂在两行之间（drawY 5.5，墨迹 ≈6..18，旧 y=10.5 会顶到画布上缘）；self-test 内含墨迹像素断言。离线出图对比用 `--preview-menubar <path>`（纯 CLI 渲染生产画法 PNG，不启动 GUI、不读凭据）。
