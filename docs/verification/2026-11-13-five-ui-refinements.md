# 五项原生 UI 精修：离线与原生验收

执行日期：2026-11-13；独立 worktree 分支 `plan/ui-refinements-20261113`。Terra 子 Agent 完成截至 `1d8fe40` 的五项实现，父 Agent 在其后复核、补测试并完成下述原生验收。原有离线记录保留，后续结果单列，不混淆首次与最终验证。

## 实际离线结果

- 每项变更先添加独立 Swift fixture 并确认对应符号/方法缺失导致 RED，再实现并确认 GREEN；由 `tests/ui_refinements_test.py` 编译执行，5 项通过。
- `python3 -m unittest discover -s tests -p 'quota_cycle_history_test.py' -v`：`Ran 33 tests`，`OK`；显式加入视觉 helper 编译依赖。
- `python3 -m unittest discover -s tests -p '*_test.py' -v`：`Ran 72 tests in 68.741s`，`OK`，退出码 0。
- `./build.sh`：退出码 0，构建成功；有原有 SecKeychain 废弃及不可达代码编译警告。
- `./GlmUsage.app/Contents/MacOS/GlmUsage --self-test`：`GlmUsage --self-test: PASS`，退出码 0。
- `./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test`：`GlmUsage --peak-test: 8/8 passed`，退出码 0。
- `bash -n build.sh scripts/update.sh scripts/release.sh`、`codesign --verify --deep --strict GlmUsage.app`、`git diff --check`：退出码均为 0。

## 父 Agent 独立审查与补充测试

- 复核相对 `d02ef22` 的全部生产 diff：仅视觉原语、每日选择数字标签、比较条和历史绘图/图标改变；周期 reducer、存储、凭据、接口、刷新频率和真实用卡路径没有修改。
- 发现历史 GUI 旧断言仅按 `已用 ` 前缀识别重复详情行，会误伤新图例“已用 / 距上限”。修复为同时要求百分号，并加入图例负例与真实数值详情行正例，原“日期下已有比例时不得再追加数值行”的要求仍保留。初次失败日志为 `parent-gui-history.log`，修复后普通/深色窄版均通过。
- 在每日原生回归中加入真实 AppKit 布局探针：220pt 时完整 `新增 999.99B` + 数据不足切换44pt双行，值标签宽度足够；恢复280pt时回到30pt单行。探针在本次测试窗口的可视区外创建并移除，不改生产布局或字号。
- 加入独立标签的即时准确 AX 值检查，以及移出窗口后 timer 停止、数字立即收敛检查。最终输出 `chip-two-row-layout-and-animation-detach: PASS`。
- 长文本探针最初未给 `.added` 传入完整“新增”前缀，宽度预期不成立；检查真实 `Outcome.text` 后修正测试输入，没有因此改变生产 chip 尺寸。
- 一轮复跑发生离开断言前日期变化、弹层被关闭及一次点击未命中预期日期。保留失败日志；将“离开保留选择”放在已知选中状态的同一主循环 turn 中断言，避免两个测试步骤之间真实 hover 插入，并增加每步 key-window 前置条件、点击 hit-test 诊断。未删除任何交互断言，也没有在 preview 中禁用动画。最后 `daily-target.log` 明确记录 key=true、canvas=true 与全部每日交互 PASS。
- 补充深色窄版历史复跑有一次未取得 key window，未算通过；在普通历史、设置和弹层均验证焦点后，独立复跑 `history-dark-narrow-focused.log` 已取得焦点并 PASS。屏幕锁定、焦点或窗口不存在仍须如实失败，不能仅凭旧 `/tmp` 结果文件宣称成功。

## 父 Agent 最终实际结果

日志根目录：`/Users/Chester/.proma/agent-workspaces/glmusage/ca6cf371-bcd1-4227-99b5-1db7487f7cdd/acceptance-logs/`。

| 检查 | 实际结果 / 最终证据 |
|---|---|
| 构建 | 多次真实重建成功；最终测试代码构建见 `daily-target-build.log`。仅原有废弃/不可达代码警告。 |
| `--self-test` | 最终源码对应构建 PASS。 |
| `--peak-test` | 8/8 PASS。 |
| 全套 Python | `accepted-unittest.log`：72 tests / 67.353s / OK。 |
| Shell / 签名 / 空白 | `bash -n`、`codesign --verify --deep --strict`、`git diff --check` 成功。 |
| 每日原生事件 | `daily-target.log`：PASS；含长chip双行/恢复、AX、移窗收尾、Tab、零/缺失、快速重定向、离开、点击、方向键、重开。 |
| 窄版每日事件 | `parent-gui-daily-narrow.log`：PASS；含320ms收敛与键盘路径。 |
| 普通历史事件 | `history-normal-final.log`：PASS；含Tab、整列命中、选择、跨页、加载更早、折叠和刷新焦点。 |
| 深色窄版历史事件 | `history-dark-narrow-focused.log`：PASS，先前焦点失败另存，未覆盖失败记录。 |
| 卡片设置 | `card-settings-final.log`：PASS。 |
| 弹层回归 | `popover-final.log`：PASS；真实缩放、锚点、滚动恢复、异步刷新、开合和屏幕两端。 |

GUI 进程串行执行，每次退出后间隔至少5秒。没有把一轮 Python 或源码检查充当原生交互通过。

## Cua 真实窗口与动画证据

均运行本 worktree 的编译产物，而不是安装版。Cua 先 `list_windows` 精确识别 PID / window_id，再展示镜像并进行后台点击、按键、滚动和截图：

1. 常规浅色：PID95177 / 窗口38207。实际滚动到每日图、周期回顾、MCP；两个图标同屏不同；每日普通柱顶微圆、零值短线和缺口仍可辨；chip 和12pt单槽可读。
2. 实际点历史第一列后，底部状态切到闭合段；方向键 Left 跨页变“历史6轮”，状态为主动用周卡；点击“返回最新周期”回到最近页。并未以静态截图代替这些交互。
3. 实际点每日图再用左右方向键切日期，录下原生窗口8秒视频。原始视频936×1980 / 120fps，检查逐帧出现2.00M→2.02M→2.11M→2.14M等中间值；日期先切换、数字收敛，纯状态夹具另证明精确0.320s。
4. 窄版新增/短历史：PID95787 / 窗口38216。`新增 2.00M` 和负向chip完整可见；唯一历史槽靠最右、100%满槽、图下100%与推算日期保留，不补五个假周期。
5. 深色经典毛玻璃：PID96001 / 窗口38225。数据不足chip、普通增幅chip、单槽、两个图标、日期和文字对比度实际可见；数据不足样例没有补出过去柱子。
6. 结束仅停止自己启动的三个精确预览PID，已结束 Cua session 与镜像。安装版原PID69515仍在运行，路径仍为 `/Users/Chester/Applications/GlmUsage.app/Contents/MacOS/GlmUsage`。

证据在本次会话工作台，含假数据，不写入代码仓库：

- `generated-images/glm-five-ui-light-history.png`：常规浅色完整真实窗口。
- `generated-images/glm-five-ui-history-selected.png` / `glm-five-ui-history-paged.png`：点击与跨页结果。
- `generated-images/glm-five-ui-narrow-bottom.png`：窄版新增chip、满槽、单条历史右对齐。
- `generated-images/glm-five-ui-dark-bottom.png`：深色经典毛玻璃。
- `generated-images/glm-animation-frames.png`：原生录屏中每100ms采样的数字变化，用于检查实际动画。
- `generated-images/glm-five-ui-native-result.png`：浅色窗口中每日/周期两张卡的展示裁切副本，输入坐标始终使用原图。
- `generated-media/glm-native-320ms.mp4`：原始窗口录屏，保留。
- `generated-media/glm-ui-native-demo.mp4`：由原始录屏裁切(136,730,660,780)、转30fps的展示副本；未合成界面或改动画时长。

## 验收结论与未覆盖范围

五项改进在本机离线与原生假数据范围内通过，保留原风格，没有整体变淡或重构刷新机制。0%、极小比例、非有限输入和100%等几何边界由纯夹具覆盖；原生可见例实际检查了普通比例与100%，不假称所有极端像素状态都实机点过。

系统“减少动态效果”的纯状态/分支和移窗回退有覆盖，但没有替用户修改系统设置做整机切换。macOS13实机、真人VoiceOver听读、真实账号跨周、真实凭据网络与真实用卡联动未验证。未安装/重载、联网读真实额度、读取真实凭据或历史、使用重置卡、合并主分支、推送或发布。
