# GlmUsage 维护约定

> 状态：当前维护约定。最后核对：2026-11-13。

## 1. 文档

- 当前行为只维护在 `README.md`、`docs/DEVELOPMENT.md` 和 `docs/project/`；`AGENTS.md` 保留本机协作与运维经验。
- 行为变化与文档更新放在同一个提交，不新增空模板或未填写流程文档。
- 不公开真实凭据、个人账号信息或不必要的环境细节。
- “凭据保存在本机”不得误写为“认证信息不发送给智谱／ZCode”。

## 2. Swift 与接口解析

- 外部 JSON 按不可信输入处理，校验类型、数值、时间、状态码和必填字段。
- 各数据区独立记录成功时间；失败保留旧值时必须显示错误或过期状态。
- 明确无有效订阅与订阅查询失败是不同结果，不得共用同一合并逻辑。
- Peak 使用 Asia/Shanghai，活动必须带起止日期；修改活动规则后补边界测试。
- 预览和自检使用假数据，不读取真实凭据、生产 pending/history 或执行真实重置卡操作。
- 周历史只采纳无警告的新鲜周响应；不得用合并后的缓存推断新轮次。API Key 分区与 OAuth 临时模式、用卡归属性及损坏保护见 `17-quota-cycle-history.md`。

## 3. 凭据与重置卡

- API key、OAuth token 只用于必要内存状态，不进入日志、状态文件、报告或提交。
- ZCode 凭据文件只读；测试使用假凭据和临时目录。
- 重置卡使用必须由用户主动触发并二次确认，定时任务不得自动使用。
- 结果未知时按卡类型复用原幂等 key，不得生成新请求盲目重试；成功后按既有延迟补刷额度。

## 4. Shell 与更新发布

- 保持 `set -euo pipefail` 和正确变量引用。
- 更新只定位目标 Bundle、可执行路径和 LaunchAgent，禁止按名称模糊 kill。
- 停止旧进程前完成下载、校验和暂存；失败必须保留或恢复旧包。
- 普通审查只运行离线测试与语法检查，不直接执行真实更新、发布或 LaunchAgent 操作。

## 5. 修改验收

代码变化后至少执行：

```bash
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test
```

更新、发布或构建脚本变化还必须执行：

```bash
python3 -m unittest discover -s tests -p '*_test.py'
bash -n build.sh scripts/update.sh scripts/release.sh
```

Popover 或交互变化需运行 `--preview-popover-test`；卡片显隐/排序/统一菜单/空态/滚动与键盘链变化需运行 `--preview-card-settings-test`。各 Popover GUI 测试必须串行并错开至少 5 秒；键盘测试要求屏幕已解锁且 Popover 成为 key window。真实接口、真实安装和系统兼容性验证单独注明，不能用离线测试替代。

## 6. 版本与提交

- 提交说明写清问题、根因、修改和验证，避免粘贴个人调试流水。
- 用户可感知的新功能使用 minor 版本，兼容性修复使用 patch 版本，安全修复明确标注。
- 正式发布只从干净、已确认并推送的提交产生，且三个发布资产必须完整。
