# AGENTS.md

## 工作区状态

GlmUsage 是 macOS 13+、Apple Silicon 的原生 AppKit 菜单栏工具，用于展示 GLM Coding Plan 额度、用量、峰谷与重置卡。应用入口与面板组装在 `GlmUsage.swift`，卡片布局与设置视图在 `PanelCustomization.swift`；无第三方依赖，构建需要 macOS 26+ SDK 与 Xcode CLT。

## 构建与验证

```bash
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test
python3 -m unittest discover -s tests -p '*_test.py'
bash -n build.sh scripts/update.sh scripts/release.sh
```

- 改代码后至少执行构建、self-test 和 peak-test；改构建/发布脚本时还要跑 Python 与 Shell 检查。完整原生 UI 命令见 `docs/DEVELOPMENT.md`。
- `--self-test` 使用临时目录和假数据，不读真实凭据、不联网。`--once` 会读凭据并联网，只有明确安排真实网络验收且确认无其他实例并发时才执行。
- Popover 与各专项 GUI 测试必须串行并错开至少 5 秒；键盘测试要求屏幕解锁、Popover 成为 key window。测试通过不等于真实网络、部署或各 macOS 版本已验收。
- 部署前必须做实际二进制 GUI 驻留冒烟并核对本次 PID 与 status.json，不能用 CLI 自检替代。LaunchAgent 为 `com.local.glm-usage`；部署、保活、多个 usage app 错开重载和历史排障见项目记忆「协议与本机运维」。

## 架构与全局红线

- `CredStore` 只读 ZCode 凭据；后台钥匙串读取必须 non-interactive，不得自行弹授权框。预览/CLI 不触发生产凭据引导。
- API Key、OAuth token 不得进入代码、提交、日志或诊断状态。查询时只发送给对应智谱/ZCode 服务。
- 额度、Token、MCP 次数是不同指标；刷新失败保留旧值和成功时间，明确无有效订阅才清除旧套餐。数据合并不对同一存储属性的两个子字段同时取 inout，避免 Swift 独占访问冲突。
- 重置卡只能由用户点击并二次确认后使用，绝不自动消费；结果未知时按卡类型复用同一幂等 key，禁止盲目重试。
- Peak 固定按 Asia/Shanghai 计算；改活动日期必须运行 `--peak-test`。
- 更新器只处理指定目标 app 与其实际 LaunchAgent，禁止按名称模糊 kill。面板更新进度原位展示，不弹独立窗口、不抢焦点；实现细节见 `docs/project/` 与项目记忆。
- 自诊断写 `~/Library/Application Support/GlmUsage/status.json`。

## 文档与协作约定

- 与君晓沟通用中文，技术名词保留英文；结论先行，避免堆砌底层细节。
- 用户说明以 `README.md` 为入口；当前构建、测试、发布和权限边界以 `docs/DEVELOPMENT.md` 为准，架构与维护约定见 `docs/project/`。判断当前行为必须核对源码和测试，历史记录不能替代当前规格。
- 工作区结构或全局命令变化时用 Edit 就地更新对应章节，不整篇重写。模块 SOP、接口参数、部署细节、排障经过和某日快照下沉到 `memory/*.md`，不要追加到本文件。

<!-- proma:memory:start -->
## 记忆维护

- **个人层（常驻）**：[user_profile.md](</Users/Chester/.proma/memory/user_profile.md>)，跨项目共享，仅记录换个项目也成立的个人背景与稳定偏好。
- **项目护栏层（常驻）**：本文件（AGENTS.md，预算 ≤4000 非空白字符），仅保留不看就会在本项目犯错的子项目结构、常用命令与全局红线；具体模块细节、排障经过和某日状态快照一律下沉到项目 memory/。
- **专题手册层（按需）**：[MEMORY.md](</Users/Chester/.proma/agent-workspaces/glmusage/memory/MEMORY.md>) 仅维护一行一条的场景路由索引（预算 ≤3500 字符，不写长篇结论摘要），详细主题按索引按需读取；过期或已合并的存量文件（含历史 project-preferences.md）通过可恢复归档移出有效入口。读取不等于核验，不编造用户事实。
<!-- proma:memory:end -->
