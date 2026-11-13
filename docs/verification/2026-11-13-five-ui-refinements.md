# 五项原生 UI 精修：离线验证

执行日期：2026-11-13；独立 worktree 分支 `plan/ui-refinements-20261113`，代码截至 `1d8fe40`。本记录不代表 GUI 验收通过。

## 实际离线结果

- 每项变更先添加独立 Swift fixture 并确认对应符号/方法缺失导致 RED，再实现并确认 GREEN；由 `tests/ui_refinements_test.py` 编译执行，5 项通过。
- `python3 -m unittest discover -s tests -p 'quota_cycle_history_test.py' -v`：`Ran 33 tests`，`OK`；显式加入视觉 helper 编译依赖。
- `python3 -m unittest discover -s tests -p '*_test.py' -v`：`Ran 72 tests in 68.741s`，`OK`，退出码 0。
- `./build.sh`：退出码 0，构建成功；有原有 SecKeychain 废弃及不可达代码编译警告。
- `./GlmUsage.app/Contents/MacOS/GlmUsage --self-test`：`GlmUsage --self-test: PASS`，退出码 0。
- `./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test`：`GlmUsage --peak-test: 8/8 passed`，退出码 0。
- `bash -n build.sh scripts/update.sh scripts/release.sh`、`codesign --verify --deep --strict GlmUsage.app`、`git diff --check`：退出码均为 0。

## 待父 Agent 原生验收

按计划串行执行 popover、daily、history、card-settings GUI 回归，间隔至少 5 秒；检查 key window、即时日期及 AX 值、320ms 动画与快速重定向、缺数及零值、窄版长胶囊不截断与高度约束、浅深色、单槽近零/近满与短历史右对齐、两图标、重新打开/移窗的定时器收尾。原生 GUI、截图/录屏和最低 macOS 13 实机均未在本执行中运行或验证。

未安装/重载、联网读真实额度、读取真实凭据或历史、使用重置卡、发布或操作生产进程。
