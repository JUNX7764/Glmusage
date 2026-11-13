# GlmUsage 五项原生 UI 精修 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 保留现有面板的字号、对比度、配色和卡片结构，实施每日柱顶部微圆角、320ms 数字过渡、涨跌胶囊、额度周期单根额度槽，以及周期回顾独立图标这五项已确认改进。

**Architecture:** 只改显示层，不改接口、统计、周期判定、连接分区和持久化。新增小型 AppKit 视觉原语、可确定性测试的数值过渡状态和胶囊视图；主文件只保留绘制调用和界面组装。复用现有绘图命中区域、分页与键盘链，不引入 React、WebView 或第三方依赖，也不把整面板增量更新重构夹带进来。

**Tech Stack:** Swift、Foundation、AppKit、SF Symbols、Python unittest、独立 Swift fixture、现有 build.sh；macOS 13+ / arm64，构建需要 macOS 26+ SDK。

---

## 0. 执行位置、授权与已确认范围

- 计划日期：2026-11-13；基线提交：`d02ef22`（`fix: make quota history card independently configurable`）。
- 分支：`plan/ui-refinements-20261113`。
- 独立 worktree：`/Users/Chester/.proma/agent-workspaces/glmusage/ca6cf371-bcd1-4227-99b5-1db7487f7cdd/ui-refinements-worktree`。
- 原始 checkout：`/Users/Chester/Documents/Zcode/Glmusage`。原目录有用户的未跟踪 `.workbuddy/`，不要搬动、清理或提交。
- **本文件是计划，不表示功能已实现。** 编写计划时没有改生产 Swift、没有构建或运行本轮原生回归。
- 实际执行用当前可用的 `@executing-plans` Skill；头部的 `superpowers:executing-plans` 是模板别名，不代表存在可调用的同名工具。真实 App 验证读取 `@cua-driver-cli`，不是用网页替身验收。
- 不安装、不重载 LaunchAgent、不结束生产 App、不联网读真实额度、不使用重置卡、不发布。执行 GUI 只运行本 worktree 编译的隔离假数据预览。系统权限/屏幕锁定阻塞时如实记录，不修改系统设置绕过。

### 五项交付及精确边界

| 编号 | 用户确认内容 | 落地规格 |
|---|---|---|
| 1 | 每日柱圆角 | 普通柱仅顶部 1.5pt 圆角、底部齐平；零值仍是原有 2pt 直线短柱；缺失仍留空；不改柱宽和高度换算 |
| 2 | 数字过渡用 320ms | 每日图所选 Token 标题数字，正常悬停/点击/方向键切换均用 0.320s ease-out 数值过渡；日期、选中柱和辅助功能准确值即时切换；快速扫过时从当前显示值重定向，不排队、不先归零 |
| 3 | 涨跌胶囊 | 每日图日环比/7日环比的值做 soft chip，保留现有正负号、文字和方向配色；不把“非高峰”、重置卡数量和历史已用百分比都强行改成同一组件 |
| 4 | 单根额度槽 | 每轮一根居中的 12pt 灰色上限槽，绿色从底部填充已用比例；0% 不画绿色，100% 填满；日期、百分比、一页六轮及右对齐不变 |
| 5 | 周期回顾独立 icon | 每日用量继续 `chart.bar`；额度周期回顾改 `clock.arrow.circlepath`，沿用 14pt 常规字重与现有主题绿 |

数字过渡不扩展到菜单栏、额度百分比、积分余额、倒计时或整个面板。320ms 是确定规格，不是待选的 150/320ms 开关。首次显示、重开面板、无变化的刷新不播放入场 count-up；“数据不足”与恢复显示立即到位。尊重系统“减少动态效果”。不要因为先前建议过立即切换，就绕开本轮用户已经选定的动画。

### 设计参考（非原生验收证据）

- 三项细节示例：`/Users/Chester/.proma/agent-workspaces/glmusage/ca6cf371-bcd1-4227-99b5-1db7487f7cdd/visual-experiments/index.html`。
- 周期柱形示例：`/Users/Chester/.proma/agent-workspaces/glmusage/ca6cf371-bcd1-4227-99b5-1db7487f7cdd/quota-history-options/index.html`，只采用中间的“单根额度槽”。
- 不照搬示例网页的大标题、外层说明、比较栏、临时演示详情框；真实 App 原有 tooltip / accessibility 中的精确数据继续保留。
- **不采用先前把全界面变淡的视觉稿。** 不降低现有文字对比度、不缩小常规字号、不改变底部刷新按钮权重。

## 1. 开工前必须理解的现状

先读 `AGENTS.md`、`docs/DEVELOPMENT.md`、`docs/project/17-quota-cycle-history.md`。

| 文件 / 基线定位 | 现状与风险 |
|---|---|
| `GlmUsage.swift:2279–2414`，`GLMDailyChartCanvas` | 6pt 宽直角柱；零日 2pt 短柱、缺失日不画；鼠标/方向键直接回调，不触发网络 |
| `GlmUsage.swift:2418–2498`，`GLMComparisonStrip` | 30pt 两分区浅底条，标签 10pt、值 11pt；包含 percent / flat / added / insufficient，不只正负百分比 |
| `GlmUsage.swift:2505–2692`，`GLMDailyUsageSectionView` | `syncSelection` 直接更新日期和数值；初始化也调用同一个函数，必须区分初次显示与交互 |
| `GlmUsage.swift:2949–2955, 3020–3040, 3225–3227` | 额度 10s 刷新后会重建视图；动画不能因每次重建反复从 0 播放或留活跃 timer |
| `GlmUsage.swift:4105–4134` | 周期卡标题当前也用 `chart.bar`；这里换独立图标 |
| `GlmUsage.swift:4883–5066`，`testDailyInteraction` | 当前 hover 后立即断言数值、步骤间隔 0.12s；加 320ms 动画必须升级测试，不允许用 preview 模式禁动画掩盖问题 |
| `Sources/GLMQuotaCycleHistoryView.swift:3–28, 66–100` | 一页六个固定槽；灰、绿两根 6pt 柱；日期/比例在基线下；选中/当前/悬停只有浅底高亮 |
| `tests/quota_cycle_history_test.py:12–20` | Swift 编译文件列表是显式的；history view 新引用视觉 helper 后必须同步加入 helper，否则模型测试会编译失败 |
| `build.sh:39–54` | 自动收集根目录和 `Sources/` Swift，无需改构建脚本；仅 `GlmUsage.swift` 通过临时 `main.swift` 作为入口 |

保持以下语义不动：已用比例按该轮自己的上限归一化；不同上限的两轮不能直接按柱高比较绝对积分；历史是最后观测，不是确定到期余额；初始推算日期、缺口、连接隔离和用卡归因不变。当前轮、固定选择和临时悬停沿用现有浅底逻辑，不新增柱组描边。

## 2. 文件边界与任务顺序

新增最多三个生产文件：

1. `Sources/GLMPanelVisuals.swift`：小型绘图原语及两个图标名，不依赖主文件业务模型。
2. `Sources/GLMAnimatedTokenValue.swift`：纯过渡状态 + 每日 Token 数字标签，不读取凭据，不设后台常驻动画。
3. `Sources/GLMDeltaChip.swift`：文本 chip，自适应明暗，不理解额度或周期业务。

测试新增：`tests/ui_refinements_test.py`、`tests/fixtures/ui-refinements/main.swift`。现有历史 fixture 保留并扩充，原生测试入口继续复用。

任务 1 → 2 → 3 → 4 → 5 → 6 顺序实施。下列每个 Step 是单一动作；不要把“所有改完再补测试”当作 TDD。代码块是最小实现起点，应按真实编译结果小范围调整；几何、时间、语义约束不能静默变更。

## Task 1: 每日柱顶部微圆角 + 离线视觉测试入口

**Files:**
- Create: `Sources/GLMPanelVisuals.swift`
- Create: `tests/ui_refinements_test.py`
- Create: `tests/fixtures/ui-refinements/main.swift`
- Modify: `GlmUsage.swift:2330–2356`，`GLMDailyChartCanvas.draw`

### Step 1: 写失败的绘图几何测试

新建 fixture，先只加入 `dailyCorners` 用例，不提前引用后续任务尚不存在的类型：

```swift
import AppKit

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

switch CommandLine.arguments.dropFirst().first {
case "dailyCorners":
    let rect = NSRect(x: 0, y: 0, width: 6, height: 20)
    let path = GLMPanelVisuals.dailyPath(in: rect, isZero: false)
    check(path.bounds == rect, "rounding must preserve width, height and baseline")
    check(path.contains(NSPoint(x: 0.1, y: 0.1)), "bottom remains square")
    check(!path.contains(NSPoint(x: 0.1, y: 19.9)), "top corner is rounded")
    let zero = GLMPanelVisuals.dailyPath(in: NSRect(x: 0, y: 0, width: 6, height: 2), isZero: true)
    check(zero.contains(NSPoint(x: 0.1, y: 1.9)), "zero-day marker remains rectangular")
    for height in [0.2, 1.0, 3.0] {
        let tiny = GLMPanelVisuals.dailyPath(in: NSRect(x: 0, y: 0, width: 6, height: height), isZero: false)
        check(tiny.bounds.minY >= 0 && tiny.bounds.maxY <= height + 0.0001, "short bars stay in bounds")
    }
    print("PASS: dailyCorners")
default:
    fputs("FAIL: unknown visual fixture\n", stderr); exit(1)
}
```

创建 Python 驱动；后续每任务只追加对应 test 方法和 Swift case：

```python
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class UIRefinementsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.binary = Path(cls.tmp.name) / "ui-refinements-tests"
        names = ("GLMPanelVisuals.swift", "GLMAnimatedTokenValue.swift", "GLMDeltaChip.swift")
        sources = [ROOT / "Sources" / name for name in names
                   if (ROOT / "Sources" / name).exists()]
        subprocess.run(["swiftc", "-target", "arm64-apple-macos13.0",
                        *map(str, sources),
                        str(ROOT / "tests/fixtures/ui-refinements/main.swift"),
                        "-o", str(cls.binary)], cwd=ROOT, check=True, timeout=120)

    def case(self, name):
        result = subprocess.run([str(self.binary), name], cwd=ROOT,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: " + name, result.stdout)

    def test_daily_corners(self):
        self.case("dailyCorners")
```

### Step 2: 运行并确认 RED

```bash
python3 -m unittest discover -s tests -p 'ui_refinements_test.py' -v
```

预期：Swift 编译报 `cannot find 'GLMPanelVisuals' in scope`。不要将其他 SDK/路径错误当成预期失败。

### Step 3: 添加最小绘图 helper

`Sources/GLMPanelVisuals.swift`：

```swift
import AppKit

enum GLMPanelVisuals {
    static let dailyCornerRadius: CGFloat = 1.5

    static func topRoundedPath(in rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        guard !rect.isEmpty else { return path }
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        guard r > 0 else { return NSBezierPath(rect: rect) }
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - r))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r),
                       radius: r, startAngle: 0, endAngle: 90)
        path.line(to: NSPoint(x: rect.minX + r, y: rect.maxY))
        path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r),
                       radius: r, startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: rect.minX, y: rect.minY))
        path.close()
        return path
    }

    static func dailyPath(in rect: NSRect, isZero: Bool) -> NSBezierPath {
        isZero ? NSBezierPath(rect: rect)
               : topRoundedPath(in: rect, radius: dailyCornerRadius)
    }
}
```

### Step 4: 接入每日绘制

只替换两处 `NSRect(...).fill()`：

```swift
// tokens == 0 分支
let zero = NSRect(x: x, y: 1, width: width, height: 2)
GLMPanelVisuals.dailyPath(in: zero, isZero: true).fill()

// 正值分支，原 height 计算保持不变
let rect = NSRect(x: x, y: 1, width: width, height: min(chartHeight, height))
GLMPanelVisuals.dailyPath(in: rect, isZero: false).fill()
```

不改 `dayIndex`、tracking area、柱宽、缺失过滤、透明度或最大值归一化。

### Step 5: 运行测试、构建和基本自检

```bash
python3 -m unittest discover -s tests -p 'ui_refinements_test.py' -v
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test
```

预期：`PASS: dailyCorners`，Python `OK`，`GlmUsage --self-test: PASS`，Peak 成功退出。构建失败先修，不跳到下一任务。

### Step 6: 提交此项

```bash
git add Sources/GLMPanelVisuals.swift tests/ui_refinements_test.py tests/fixtures/ui-refinements/main.swift GlmUsage.swift
git commit -m "feat: soften daily chart top corners"
```

## Task 2: 每日 Token 数字 320ms 过渡

**Files:**
- Create: `Sources/GLMAnimatedTokenValue.swift`
- Modify: `GlmUsage.swift:2519–2521, 2633–2639, 2669–2688`
- Modify: `GlmUsage.swift:4988–5066`，原生每日交互回归
- Modify: `tests/fixtures/ui-refinements/main.swift`
- Modify: `tests/ui_refinements_test.py`

### Step 1: 添加纯状态失败测试

在 fixture switch 中追加以下 case；Python 加 `test_token_transition` 调用 `self.case("tokenTransition")`。

```swift
case "tokenTransition":
    var s = GLMTokenTransition()
    s.set(100, at: 0, animated: true)
    check(s.display == 100 && !s.isAnimating, "first display snaps")
    s.set(200, at: 10, animated: true)
    check(s.isAnimating, "interaction animates")
    check(s.advance(at: 10) == 100, "starts at current value")
    let middle = s.advance(at: 10.160)!
    check(abs(middle - 187.5) < 0.001, "320ms cubic ease-out midpoint")
    s.set(50, at: 10.160, animated: true)
    check(abs(s.display! - middle) < 0.001, "retarget without zero or jump")
    check(s.advance(at: 10.481) == 50 && !s.isAnimating, "latest target wins")
    s.set(nil, at: 11, animated: true)
    check(s.display == nil && s.target == nil && !s.isAnimating, "missing cancels")
    s.set(0, at: 12, animated: true)
    check(s.display == 0 && !s.isAnimating, "recovery and zero are real values")
    s.set(1_000_000, at: 13, animated: false)
    check(s.display == 1_000_000 && !s.isAnimating, "reduce motion snaps")
    s.set(.nan, at: 14, animated: true)
    check(s.target == nil && !s.isAnimating, "nonfinite values do not animate")
    print("PASS: tokenTransition")
```

### Step 2: 运行 RED

```bash
python3 -m unittest discover -s tests -p 'ui_refinements_test.py' -v
```

预期：尚不存在 `GLMTokenTransition`。已有 dailyCorners 不能被删除来换绿灯。

### Step 3: 实现纯过渡状态

`Sources/GLMAnimatedTokenValue.swift` 前半段：

```swift
import AppKit

struct GLMTokenTransition {
    static let duration: TimeInterval = 0.320
    private(set) var display: Double?
    private(set) var target: Double?
    private(set) var isAnimating = false
    private var from = 0.0
    private var startedAt: TimeInterval = 0

    mutating func set(_ raw: Double?, at now: TimeInterval, animated: Bool) {
        _ = advance(at: now)
        guard let value = raw, value.isFinite, value >= 0 else {
            display = nil; target = nil; isAnimating = false
            return
        }
        target = value
        guard animated, let current = display, current != value else {
            display = value; isAnimating = false
            return
        }
        from = current; startedAt = now; isAnimating = true
    }

    @discardableResult
    mutating func advance(at now: TimeInterval) -> Double? {
        guard isAnimating, let target else { return display }
        let t = min(1, max(0, (now - startedAt) / Self.duration))
        display = from + (target - from) * (1 - pow(1 - t, 3))
        if t >= 1 { display = target; isAnimating = false }
        return display
    }
}
```

### Step 4: 添加只在交互时运行的原生标签

同文件后半段：

```swift
final class GLMAnimatedTokenLabel: NSTextField {
    private let format: (Double) -> String
    private var transition = GLMTokenTransition()
    private var timer: Timer?
    private var motionObserver: NSObjectProtocol?
    private var exactText = ""
    var isAnimating: Bool { transition.isAnimating }

    init(format: @escaping (Double) -> String) {
        self.format = format
        super.init(frame: .zero)
        isEditable = false; isSelectable = false
        isBordered = false; drawsBackground = false
        maximumNumberOfLines = 1; lineBreakMode = .byTruncatingTail
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self?.finishImmediately()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setTokens(_ tokens: Double?, animated: Bool) {
        timer?.invalidate(); timer = nil
        let allowed = animated && window != nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        transition.set(tokens, at: ProcessInfo.processInfo.systemUptime, animated: allowed)
        exactText = transition.target.map(format) ?? "数据不足"
        render()
        guard transition.isAnimating else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.transition.advance(at: ProcessInfo.processInfo.systemUptime)
            self.render()
            if !self.transition.isAnimating {
                self.timer?.invalidate(); self.timer = nil
            }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func render() {
        stringValue = transition.display.map(format) ?? "数据不足"
    }

    private func finishImmediately() {
        setTokens(transition.target, animated: false)
    }

    override func accessibilityValue() -> Any? { exactText }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { finishImmediately() }
    }

    deinit {
        timer?.invalidate()
        if let motionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(motionObserver)
        }
    }
}
```

注意：不得改用 wall clock 的 `Date()` 插值；不为动画新设后台轮询；不对 AX 值逐帧报中间数。上述 label 本身提供准确目标值，canvas 的既有 `updateAccessibilityValue()` 继续即时生效。

### Step 5: 接入每日区块，区分初始化与交互

将 `valueLabel` 创建改为：

```swift
private let valueLabel = GLMAnimatedTokenLabel { "\(Fmt.tokens($0)) Token" }
```

把 `syncSelection` 改为：

```swift
private func syncSelection(_ index: Int, animated: Bool = false) {
    let buckets = canvas.dayBuckets
    guard buckets.indices.contains(index) else { return }
    let bucket = buckets[index]
    dateLabel.stringValue = Self.dayText(for: bucket.day)
    valueLabel.textColor = bucket.tokens == nil ? .secondaryLabelColor : .labelColor
    valueLabel.setTokens(bucket.tokens, animated: animated)
}
```

回调改 `self?.syncSelection(index, animated: true)`；初始化的 `syncSelection(canvas.selectedIndex)` 保持 `animated: false`。原 `valueLabelIdentifier`、11pt semibold、压缩优先级和右对齐不改。不要让重开或 10s 重建触发动画。

### Step 6: 更新原生回归的等待方式

`testDailyInteraction` 不能再在 hover 后立即比较渲染字符串，也不能全局把 0.12s 改成大 sleep。保留日期即时断言，数值用条件轮询等待最终值：

```swift
func waitForValue(_ expected: String, timeout: TimeInterval = 0.8) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while valueLabel.stringValue != expected,
          ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return valueLabel.stringValue == expected
}
```

在原 `verify` 中先断言日期，再 `guard waitForValue(expectedValue) else { fail(...) }`。补充一个快速重定向步骤：连续 `hover(5); hover(20); verify(...index:20)`，再等待 0.4s 确认不会被旧完成回调覆盖。缺失日必须当次立刻成为“数据不足”；零值为 `0 Token`。动画刚开始时，断言 `valueLabel.accessibilityValue()` 已是目标准确值。

在系统未开启减少动态效果时，普通 hover 后检查 `GLMAnimatedTokenLabel.isAnimating == true`，证明没有以测试模式绕过动画；若系统确实减少动态效果，则记录这项时序外观断言跳过，但最终值、纯状态 320ms 用例仍必须通过。不要替用户修改系统辅助功能选项。

### Step 7: 跑测试、基本门禁与原生每日回归

```bash
python3 -m unittest discover -s tests -p 'ui_refinements_test.py' -v
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-daily-test --preview-daily-gaps
```

预期：新增 `PASS: tokenTransition`；`GLM daily test: PASS`。GUI 进程结束后等待至少 5s，才启动下一个 GUI。若 key window 不成立必须报失败/阻塞，不能删掉 Tab 可达断言。

### Step 8: 提交此项

```bash
git add Sources/GLMAnimatedTokenValue.swift GlmUsage.swift tests/ui_refinements_test.py tests/fixtures/ui-refinements/main.swift
git commit -m "feat: animate selected daily token values over 320ms"
```

## Task 3: 日环比 / 7日环比 soft chip

**Files:**
- Create: `Sources/GLMDeltaChip.swift`
- Modify: `GlmUsage.swift:2418–2498`，`GLMComparisonStrip`
- Modify: `tests/fixtures/ui-refinements/main.swift`
- Modify: `tests/ui_refinements_test.py`

### Step 1: 写失败的尺寸与排版决策测试

新增 fixture case `deltaChip` 和 Python `test_delta_chip`。用现有真实输出字符串覆盖全部四种 Outcome，不在 helper 中重算比较数据：

```swift
case "deltaChip":
    let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    for value in ["+100.0%", "-22.5%", "持平", "新增 9.99B", "数据不足"] {
        let size = GLMDeltaChip.size(for: value, font: font)
        check(size.height == 20 && size.width > 12, "chip has text and padding")
    }
    check(!GLMDeltaChip.requiresTwoRows(halfWidth: 135, captionWidth: 40, chipWidth: 65), "normal width stays one row")
    check(GLMDeltaChip.requiresTwoRows(halfWidth: 105, captionWidth: 40, chipWidth: 77), "narrow long values must not truncate numbers")
    print("PASS: deltaChip")
```

### Step 2: 运行 RED

```bash
python3 -m unittest discover -s tests -p 'ui_refinements_test.py' -v
```

预期：`GLMDeltaChip` 未定义。

### Step 3: 实现最小 chip 原语

```swift
import AppKit

final class GLMDeltaChip: NSView {
    let valueLabel = NSTextField(labelWithString: "")
    private let foreground: NSColor

    static func size(for text: String, font: NSFont) -> NSSize {
        NSSize(width: ceil((text as NSString).size(withAttributes: [.font: font]).width) + 12,
               height: 20)
    }

    static func requiresTwoRows(halfWidth: CGFloat, captionWidth: CGFloat,
                                chipWidth: CGFloat) -> Bool {
        captionWidth + 4 + chipWidth > halfWidth
    }

    init(text: String, foreground: NSColor) {
        self.foreground = foreground
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true; layer?.cornerRadius = 9
        valueLabel.stringValue = text
        valueLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        valueLabel.textColor = foreground
        valueLabel.maximumNumberOfLines = 1
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override var intrinsicContentSize: NSSize {
        Self.size(for: valueLabel.stringValue, font: valueLabel.font!)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer?.backgroundColor = foreground.withAlphaComponent(dark ? 0.16 : 0.10).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}
```

### Step 4: 替换两项比较值，不改比较逻辑

用下面完整实现替换 `GLMComparisonStrip`。它保留原方向动态色、caption、tooltip 与分隔结构；不重算 Outcome。外层背景仅减到 0.02，数字字号与颜色不变。

```swift
final class GLMComparisonStrip: NSView {
    private struct Entry {
        let caption: NSTextField
        let chip: GLMDeltaChip
        let row: NSStackView
    }
    private var entries: [Entry] = []
    private var stripHeight: NSLayoutConstraint!
    private var stackHeight: NSLayoutConstraint!
    private var dividerHeights: [NSLayoutConstraint] = []
    private var isTwoRows = false

    init(pairs: [(label: String, outcome: GLMUsageComparison.Outcome)]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stripHeight = heightAnchor.constraint(equalToConstant: 30)
        stripHeight.isActive = true
        let background = GLMPillBackground()
        background.radius = 6; background.backgroundAlpha = 0.02
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let stack = NSStackView()
        stack.orientation = .horizontal; stack.distribution = .fill
        stack.alignment = .centerY; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stackHeight = stack.heightAnchor.constraint(equalToConstant: 30)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor), stackHeight,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])
        var firstHalf: NSView?
        for (index, pair) in pairs.enumerated() {
            if index > 0 {
                let divider = NSBox(); divider.boxType = .separator
                divider.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(divider)
                let h = divider.heightAnchor.constraint(equalToConstant: 18)
                dividerHeights.append(h)
                NSLayoutConstraint.activate([divider.widthAnchor.constraint(equalToConstant: 1), h])
            }
            let half = NSView()
            half.translatesAutoresizingMaskIntoConstraints = false
            half.toolTip = index == 0 ? "今日（未结束）与前一日比较" : "最近 7 天（含今日）与此前 7 天比较"
            stack.addArrangedSubview(half)
            half.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
            if let firstHalf {
                half.widthAnchor.constraint(equalTo: firstHalf.widthAnchor).isActive = true
            } else { firstHalf = half }
            let caption = NSTextField(labelWithString: pair.label)
            caption.font = .systemFont(ofSize: 10)
            caption.textColor = .secondaryLabelColor
            let valueColor: NSColor
            switch pair.outcome.direction {
            case .increase:
                valueColor = NSColor(name: nil) { appearance in
                    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    return dark ? NSColor(srgbRed: 0.44, green: 0.78, blue: 0.61, alpha: 1)
                                : NSColor(srgbRed: 0.13, green: 0.45, blue: 0.31, alpha: 1)
                }
            case .decrease:
                valueColor = NSColor(name: nil) { appearance in
                    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    return dark ? NSColor(srgbRed: 0.91, green: 0.64, blue: 0.37, alpha: 1)
                                : NSColor(srgbRed: 0.64, green: 0.32, blue: 0.08, alpha: 1)
                }
            case .neutral: valueColor = .secondaryLabelColor
            }
            let chip = GLMDeltaChip(text: pair.outcome.text, foreground: valueColor)
            let row = NSStackView(views: [caption, chip])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 4
            row.translatesAutoresizingMaskIntoConstraints = false
            half.addSubview(row)
            NSLayoutConstraint.activate([
                row.centerXAnchor.constraint(equalTo: half.centerXAnchor),
                row.centerYAnchor.constraint(equalTo: half.centerYAnchor),
                row.widthAnchor.constraint(lessThanOrEqualTo: half.widthAnchor)
            ])
            entries.append(Entry(caption: caption, chip: chip, row: row))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        guard bounds.width > 0, !entries.isEmpty else { return }
        let available = bounds.width - 8 - CGFloat(max(0, entries.count - 1))
        let halfWidth = max(0, available / CGFloat(entries.count))
        let next = entries.contains {
            GLMDeltaChip.requiresTwoRows(halfWidth: halfWidth,
                captionWidth: $0.caption.intrinsicContentSize.width,
                chipWidth: $0.chip.intrinsicContentSize.width)
        }
        guard next != isTwoRows else { return }
        isTwoRows = next
        for entry in entries {
            entry.row.orientation = next ? .vertical : .horizontal
            entry.row.alignment = next ? .centerX : .centerY
            entry.row.spacing = next ? 2 : 4
        }
        stripHeight.constant = next ? 44 : 30
        stackHeight.constant = next ? 44 : 30
        dividerHeights.forEach { $0.constant = next ? 30 : 18 }
    }
}
```

### Step 5: 检查窄面板回退接线

确认 `layout()` 用固有文本宽度而不是当前被压缩后的 frame 决策，并同时更新外层与 stack 的高度。常规 ±百分比维持单行；窄版“新增…”极端值允许条增高至 44pt。不要改整个面板字号，不删“新增”，不截断数字。若在真实布局中出现 Auto Layout 警告，先修约束，不靠移除窄版测试过关。

### Step 6: 运行单测、构建和四类状态预览

```bash
python3 -m unittest discover -s tests -p 'ui_refinements_test.py' -v
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test
```

预期：`PASS: deltaChip`，原 daily comparison 的离线计算用例仍通过。下面逐个 GUI 运行、关闭自己的预览 PID 后间隔 ≥5s：

```bash
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-daily-basezero --preview-narrow
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-daily-unavailable --preview-narrow
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-daily-insufficient
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-dark
```

预期：新增、数据不足、普通增减、持平都能阅读；tooltip 的比较口径仍是今日/近7日，不随悬停选中日重算。浅深主题即时切换 chip 底色；PeakBadge 和历史百分比没有被改形。

### Step 7: 提交此项

```bash
git add Sources/GLMDeltaChip.swift GlmUsage.swift tests/ui_refinements_test.py tests/fixtures/ui-refinements/main.swift
git commit -m "feat: present daily deltas as soft chips"
```

## Task 4: 周额度回顾改为单根额度槽

**Files:**
- Modify: `Sources/GLMPanelVisuals.swift`
- Modify: `Sources/GLMQuotaCycleHistoryView.swift:3–28, 66–100, 117`
- Modify: `tests/quota_cycle_history_test.py:12–20`
- Modify: `tests/fixtures/quota-cycle-history/main.swift`
- Modify: `tests/fixtures/ui-refinements/main.swift`
- Modify: `tests/ui_refinements_test.py`

### Step 1: 写失败的单槽几何测试

新增 `historyTrack` case；Python 对应增加 `test_history_track`：

```swift
case "historyTrack":
    let column = NSRect(x: 20, y: 0, width: 43, height: 92)
    let zero = GLMPanelVisuals.historyBar(in: column, baseline: 31, usedPercent: 0)
    check(zero.track.width == 12 && zero.track.midX == column.midX, "one centered 12pt slot")
    check(zero.fill == nil, "0% does not fabricate usage")
    let half = GLMPanelVisuals.historyBar(in: column, baseline: 31, usedPercent: 50)
    check(abs(half.fill!.height / half.track.height - 0.5) < 0.0001, "fill is normalized")
    check(half.fill!.minY == half.track.minY && half.fill!.width == half.track.width, "fill shares baseline and x")
    let full = GLMPanelVisuals.historyBar(in: column, baseline: 31, usedPercent: 100)
    check(full.fill == full.track, "100% fills the slot")
    let tiny = GLMPanelVisuals.historyBar(in: column, baseline: 31, usedPercent: 0.4)
    check(tiny.fill!.height < 1, "tiny use is not inflated to a 2pt bar")
    check(GLMPanelVisuals.historyBar(in: column, baseline: 31, usedPercent: .nan).fill == nil, "nonfinite does not fill")
    print("PASS: historyTrack")
```

### Step 2: 运行 RED

```bash
python3 -m unittest discover -s tests -p 'ui_refinements_test.py' -v
```

预期：`historyBar` 不存在。

### Step 3: 添加不依赖业务模型的单槽几何函数

加入 `GLMPanelVisuals`：

```swift
static func historyBar(in column: NSRect, baseline: CGFloat, usedPercent: Double)
    -> (track: NSRect, fill: NSRect?) {
    let width = min(CGFloat(12), max(0, column.width - 4))
    let height = max(0, column.height - baseline - 4)
    let track = NSRect(x: column.midX - width / 2, y: baseline,
                       width: width, height: height)
    guard usedPercent.isFinite, usedPercent > 0, !track.isEmpty else {
        return (track, nil)
    }
    let fraction = CGFloat(min(100, max(0, usedPercent)) / 100)
    let fill = NSRect(x: track.minX, y: track.minY,
                      width: track.width, height: track.height * fraction)
    return (track, fill)
}
```

### Step 4: 替换历史绘图中的两根柱

在 `GLMQuotaHistoryCanvas.draw` 保持高亮背景、日期与百分比绘制代码不动，替换 `center - 8` / `center + 2` 两根柱：

```swift
let geometry = GLMPanelVisuals.historyBar(in: rect,
    baseline: GLMQuotaHistoryGeometry.plotBaseline,
    usedPercent: record.lastObservation.usedPercent)
let trackPath = NSBezierPath(roundedRect: geometry.track, xRadius: 2, yRadius: 2)
NSColor.secondaryLabelColor.withAlphaComponent(0.25).setFill()
trackPath.fill()
if let fill = geometry.fill {
    NSGraphicsContext.saveGraphicsState()
    trackPath.addClip()
    accent.withAlphaComponent(highlighted ? 1 : 0.72).setFill()
    // 填充与灰槽完全同位，底部被 trackPath 裁剪为同一轮廓。
    GLMPanelVisuals.topRoundedPath(in: fill, radius: 2).fill()
    NSGraphicsContext.restoreGraphicsState()
}
```

不加 min-height 伪造 0% / 0.4% 的已用面积。每轮原有精确百分比标签继续保留，小于1%仍显示 `<1%`，超过99%但未满仍显示 `>99%`；不能因为像素接近满槽就标“用满”。图例从 `上限 / 已用` 改为 `已用 / 距上限`，保持 10pt。

### Step 5: 修复显式测试编译依赖

在 `tests/quota_cycle_history_test.py` 的 `swiftc` 列表加入：

```python
str(ROOT / "Sources/GLMPanelVisuals.swift"),
```

必须在执行历史回归前完成。不要把主文件加入这个模型 fixture，否则会引入第二个入口和真实启动路径。

### Step 6: 增补历史 fixture 的几何断言

在 `chartGeometry` 现有 220 / 280 两种画布宽度循环里追加每列单槽居中、不越界、底部高于日期区的断言；继续执行原 `chartPercentageLabels`、`shortHistoryRightAligned`、`historyPaging`。

```swift
for column in frames {
    let bar = GLMPanelVisuals.historyBar(in: column, baseline: 31, usedPercent: 68)
    check(bar.track.minX >= column.minX && bar.track.maxX <= column.maxX, "track within its hit column")
    check(bar.track.minY == 31 && bar.fill!.minY == 31, "one aligned baseline")
    check(bar.track.midX == column.midX, "labels and one bar share center")
}
```

不改 `record(at:)` 的整列命中方式，不缩小成只命中 12pt 柱体。

### Step 7: 运行单测和构建门禁

```bash
python3 -m unittest discover -s tests -p 'ui_refinements_test.py' -v
python3 -m unittest discover -s tests -p 'quota_cycle_history_test.py' -v
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test
```

预期：两个 Python suite `OK`，新增 `PASS: historyTrack`；历史归因、分区和存储用例全部不受影响。

### Step 8: 原生历史回归与短记录预览

以下逐个运行并相隔 ≥5s：

```bash
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-popover --preview-quota-history --preview-quota-history-test
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-quota-history --preview-quota-history-state=short --preview-narrow
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-quota-history --preview-quota-history-state=empty
```

预期：事件回归成功、短历史靠右、不补灰色空槽、空态无伪造周期；鼠标离开恢复固定选择；跨页方向键和刷新焦点不丢。

### Step 9: 提交此项

```bash
git add Sources/GLMPanelVisuals.swift Sources/GLMQuotaCycleHistoryView.swift tests/ui_refinements_test.py tests/fixtures/ui-refinements/main.swift tests/quota_cycle_history_test.py tests/fixtures/quota-cycle-history/main.swift
git commit -m "feat: combine quota cycle bars into single capacity tracks"
```

## Task 5: 周期回顾独立 SF Symbol

**Files:**
- Modify: `Sources/GLMPanelVisuals.swift`
- Modify: `GlmUsage.swift:2540, 4108`
- Modify: `tests/fixtures/ui-refinements/main.swift`
- Modify: `tests/ui_refinements_test.py`

### Step 1: 添加失败的图标测试

新增 `distinctSymbols` case 及 Python `test_distinct_symbols`：

```swift
case "distinctSymbols":
    check(GLMPanelVisuals.dailySymbol != GLMPanelVisuals.historySymbol, "history and daily must differ")
    check(GLMPanelVisuals.dailySymbol == "chart.bar", "keep daily identity")
    check(GLMPanelVisuals.historySymbol == "clock.arrow.circlepath", "history means cycles")
    check(NSImage(systemSymbolName: GLMPanelVisuals.historySymbol, accessibilityDescription: nil) != nil,
          "history symbol exists on this runtime")
    print("PASS: distinctSymbols")
```

### Step 2: 运行 RED

```bash
python3 -m unittest discover -s tests -p 'ui_refinements_test.py' -v
```

预期：两个 symbol 常量尚不存在。

### Step 3: 添加常量并接入两个真实位置

```swift
// GLMPanelVisuals 内
static let dailySymbol = "chart.bar"
static let historySymbol = "clock.arrow.circlepath"
```

```swift
// GLMDailyUsageSectionView 中创建图标的位置
let icon = NSImageView(image: NSImage(systemSymbolName: GLMPanelVisuals.dailySymbol,
                                    accessibilityDescription: nil) ?? NSImage())

// buildPanel() 中周期回顾的标题组装
let historyHeader = section("额度周期回顾", icon: GLMPanelVisuals.historySymbol,
    expanded: historyExpanded, action: #selector(toggleHistory))
```

保持图标 tint 和 14pt regular 不变。图标是装饰，不增加重复 VoiceOver 名称；标题仍负责“展开/收起额度周期回顾”的无障碍标签。

### Step 4: 测试与构建

```bash
python3 -m unittest discover -s tests -p 'ui_refinements_test.py' -v
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test
```

预期：`PASS: distinctSymbols`；在实际原生预览中同时看到每日用量和周期回顾，确认不是空白 fallback，且两个图标在 14pt 下明显可区分。最低 macOS 13 兼容性须依符号可用性资料/实机验证，不能仅靠当前系统 NSImage 非 nil 声称旧系统已实测。

### Step 5: 提交此项

```bash
git add Sources/GLMPanelVisuals.swift GlmUsage.swift tests/ui_refinements_test.py tests/fixtures/ui-refinements/main.swift
git commit -m "feat: give quota cycle history a distinct symbol"
```

## Task 6: 联合验收、文档与可见交付

这是五项功能的验证收尾，不是第六项功能。不做全局布局重构，不安装更新。

**Files:**
- Modify: `docs/project/17-quota-cycle-history.md`
- Modify: `docs/DEVELOPMENT.md`
- Modify: `CHANGELOG.md`
- Create: `docs/verification/2026-11-13-five-ui-refinements.md`
- Optional Modify: `README.md`（仅在替换真实假数据截图时）

### Step 1: 运行完整离线门禁

```bash
git status --short
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test
python3 -m unittest discover -s tests -p '*_test.py' -v
bash -n build.sh scripts/update.sh scripts/release.sh
codesign --verify --deep --strict GlmUsage.app
git diff --check
```

预期：所有测试成功、签名校验通过、无空白错误。记录实际测试数和输出，不把本文中的 Expected 当成已通过证据。新文件只声明类型，确保没有新增 top-level main。

### Step 2: 串行跑原生 GUI 回归

屏幕解锁、取得 key window；每次 GUI 正常结束后间隔 ≥5s。自动退出测试必须等待退出码，不能后台丢着再启下一实例。

```bash
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-popover-test
sleep 5
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-daily-test --preview-daily-gaps
sleep 5
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-popover --preview-quota-history --preview-quota-history-test
sleep 5
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-card-settings-test
```

预期：popover、daily、history、card settings 均 PASS，且退出码0。禁止仅从旧 `/tmp/*_test_result.txt` 判通过；依据本次进程输出和本次退出状态。

### Step 3: 在本次构建的真实原生窗口观察五项效果

按 `@cua-driver-cli` 的流程先确认窗口、展示目标镜像，再操作并截图。用隔离假数据命令：

```bash
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-quota-history --preview-daily-gaps
```

此命令是持续窗口，不会自动退出：只对自己启动并确认的 PID 正常退出；用户生产 App 不动。启动其他 usage app 或下一个预览必须错开 ≥5s。

必须看到而不是只读源码推断：

- 每日正常柱顶部微圆，零值/缺失仍可区别，柱高和基线不变。
- 逐日扫过与快速来回扫过都为 320ms 数值过渡；最后停下的日期与最终数值一致。不会从0重播、不会旧值反扑。需要录屏才能证明动画过程时，保存短录屏；静态截图不证明时序。
- 鼠标离开仍保留最后选中日；点击后左右方向键和 Tab 可达继续有效。
- 当日/近7日比较仍是原口径；chip 的缺数/新增/持平不误标为好坏。
- 每个周期只剩一根灰槽加绿色填充；0%、近0%、近100%、100% 均按真实比例，标签不造假。
- 每页6轮、记录不足靠右；历史/当前/待确认/未保存的文字继续有效，卡片设置不会丢失历史卡。
- 每日图 `chart.bar` 与周期回顾 `clock.arrow.circlepath` 同屏可分辨。
- 挂着预览观察至少10s；假数据 preview 无生产轮询，不能据此声称真实10s刷新已验证。可在隔离测试中主动触发一次 `rebuildPanel()`，核对已选状态和 timer 收尾，不增加真实请求。

### Step 4: 补齐明暗与窄版状态检查

逐个假数据预览、退出后间隔 ≥5s：

```bash
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-quota-history --preview-dark --preview-narrow
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-daily-basezero --preview-narrow
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-daily-unavailable --preview-narrow
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-quota-history --preview-quota-history-state=unsaved
./GlmUsage.app/Contents/MacOS/GlmUsage --preview --preview-quota-history --preview-background=classicMaterial
```

原生截图看实际对比度、布局及图标，不用浏览器的概念图顶替。系统减少动态效果若已启用，验证即时准确值；若未启用，只报告纯状态/分支测试覆盖，不擅自切系统选项来制造“实测”。

### Step 5: 同步当前文档

- `docs/project/17-quota-cycle-history.md`：把“双柱上限/已用”改为“一根100%灰槽，绿色填充已用比例”；保留上限归一化、初始未知、结束观测和图下百分比规则。
- `docs/DEVELOPMENT.md`：登记新增三个显示文件和 `ui_refinements_test.py`；说明每日数字320ms、首次/缺数/减少动态效果回退，以及窄长 chip 可增高。
- `CHANGELOG.md`：按当前仓库格式加入五项改动及无业务口径变化说明，不随意修改版本号或创建 tag。
- `docs/verification/2026-11-13-five-ui-refinements.md`：真实执行日期、worktree/commit、测试命令和退出码、截图/录屏路径、逐项通过/阻塞、未做真实网络和部署说明。
- 不把圆角和动画细节塞进 `AGENTS.md`。本轮没有全局命令或入口红线变化，不做无意义项目地图维护。

### Step 6: 提交验证与文档

```bash
git add docs/project/17-quota-cycle-history.md docs/DEVELOPMENT.md CHANGELOG.md docs/verification/2026-11-13-five-ui-refinements.md
git commit -m "docs: verify five native UI refinements"
```

若更新 README 截图，则另外只暂存本次真实产物对应的 `README.md` / `docs/images/glm-usage-preview.png`，不要把用户其他图片一起 add。

### Step 7: 用户交付与执行边界

先展示实际原生效果（静态并排图 + 必要的数字动画短录屏），再用几行总结五项是否完成、测试结果、已知限制。用户确认前不安装、重载或发布。只对最终需用户拿走的图/录屏/报告调用 `Present`，普通源文件不 Present。

## 3. 完成判据（执行时逐项勾选）

- [ ] 1. 每日普通柱 1.5pt 顶圆角，零值2pt直线、缺失留空。
- [ ] 2. 每日选中 Token 数字固定320ms；快速重定向、缺数/0/单位、减少动态效果和移窗收尾已验证；AX 目标值即时准确。
- [ ] 3. 两项比较值 soft chip；正负/持平/新增/数据不足全覆盖，280pt窄面板无数字截断。
- [ ] 4. 周期每轮单根12pt额度槽；0%/100%/接近边界不造假；比例、标签、翻页与历史口径不变。
- [ ] 5. 周期回顾 icon 为 `clock.arrow.circlepath`，每日仍为 `chart.bar`，真实原生同屏可区分。
- [ ] 完整离线门禁通过；实际原生测试与网页示例分开报告；无生产凭据/历史/LaunchAgent副作用。
- [ ] 文档与变更日志同步；不存在未经用户确认的整体变淡、字体缩小或面板重构。

## 4. 计划交接

计划已写在独立 worktree；执行前重新 `git status --short`，确认没有并发修改。主文件、视觉 helper 和每日测试有共享接缝，不适合五个子会话同时改同一文件。

两种执行方式：

1. **本会话继续**：逐项实施并在每项完成后检查；仅将可独立隔离的探索/对抗审查按需委派，不能因为模板写了 subagent 就创建依赖串行的并发实现。
2. **独立会话执行**：新会话绑定本文 worktree，加载 `@executing-plans`，按任务批次实施和检查。

本计划本身不授予真实账号网络验收、安装/重载、危险 Git 或公开发布权限。
