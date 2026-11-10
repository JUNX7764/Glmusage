# GlmUsage 当前架构概览

> 状态：当前架构摘要。最后核对：2026-11-11。
> 本文解释模块与边界，函数级行为以源码和测试为准。

## 1. 应用形态

GlmUsage 是 macOS 13+、Apple Silicon 的原生 AppKit 菜单栏应用，当前 Swift 实现集中在 `GlmUsage.swift`，无 Swift Package 依赖。面板使用原生 `NSPopover`。

应用身份保持为：

- 仓库：`JUNX7764/Glmusage`
- Bundle / LaunchAgent：`com.local.glm-usage`
- 应用：`GlmUsage.app`

## 2. 模块边界

| 模块 | 当前职责 |
|---|---|
| `CredStore` | 接收 `GLM_API_KEY`，只读解密 ZCode `enc:v1` 凭据，识别 `enc:v2` 兼容状态 |
| `Fetcher` | 智谱额度、模型、工具、订阅和 ZCode 重置卡请求 |
| `GLMStartPlanUsage` | 只读 ZCode 请求用量表，将赠送用量按周期、模型和自然日补入现有统计 |
| `Peak` | 高峰、非高峰和限时活动的本地时段计算 |
| `UpdateChecker` | 检查 GitHub Release 和更新资产 |
| `UpdateProgressController` | 后台更新、进度恢复和错误展示 |
| `AppDelegate` | 原生 Popover、刷新调度、重置卡操作、自启和状态聚合 |
| `GLMOfflineRegression` | 使用临时目录和假数据的离线自检 |

单文件是当前实现状态，不是永久架构约束。后续拆分时优先分离凭据、网络、Peak、更新和 UI。

## 3. 主要数据流

### 额度、用量与订阅

ZCode `enc:v1` 凭据或 `GLM_API_KEY` → 内存 API Key / OAuth token → 智谱与 ZCode 接口 → 新鲜度和错误合并 → Popover 与诊断状态。

模型统计在同一刷新中合并本机 `model_usage` 的国内 Start Plan 请求。逐次请求的时间和 Token 总数用于周期汇总及日图，同名模型合并；服务端原始值加本次本机快照后进入新鲜度处理，重复刷新不会累加旧值。SQLite 只读，查询与网络回调在后台运行；无本机请求表时保留原统计，读取异常时沿用上次完整值。环境变量覆盖 API key 时只使用服务端统计。

凭据文件保持只读。认证信息会发送给对应智谱／ZCode 服务，不发送到开发者自有服务器，也不得写入仓库、日志或状态文件。

### 重置卡

状态查询 → 可用卡与到期时间展示 → 用户主动点击和二次确认 → 带幂等 key 的使用请求 → 额度刷新。

网络或 5xx 导致结果未知时，按卡类型保存并复用原幂等 key。预览模式禁用真实操作，任何定时刷新不得自动用卡。

### 自动更新

GitHub Release → 可安装版本选择 → ZIP / SHA256 下载 → 身份、版本、签名与离线自检 → 暂存 → 停止目标进程 → 换包 → 健康检查 → 成功清理或失败回滚。

更新器只处理当前应用路径和 `com.local.glm-usage`，不得按名称模糊终止其他进程。

## 4. 信任边界

- 智谱监控接口与 ZCode 逆向接口的稳定性不同，重置卡接口变化不得影响其他额度区块。
- OAuth token 可能过期，重置卡失败必须独立降级，不能伪造成卡数为零。
- ZCode 3.18.0 默认通过系统钥匙串管理新版登录凭据。新版凭据触发兼容提示；用户可提供套餐 API Key 查询服务端额度与用量，在 ZCode 内管理重置卡。
- GitHub Release 与 SHA256 来自同一信任源；ad-hoc 签名不提供独立发布者身份验证。
- Peak 活动日期是带时效的配置，必须可测试并在过期后自动失效。
- 离线 mock、真实接口验证和真实安装验收是不同证据。
- 当前没有 CI 强制发布门禁，也没有完整系统版本兼容性矩阵。
