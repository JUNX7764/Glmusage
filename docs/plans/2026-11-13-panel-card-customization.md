# Panel Card Customization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将页头背景按钮升级为统一的「···」面板设置入口，支持六张内容卡片显示/隐藏、纵向排序、状态持久化和恢复默认，同时保留固定恢复入口、背景回退规则、键盘可达性与滚动稳定性。

**Architecture:** 新增独立 `PanelCustomization.swift`，用稳定卡片 ID 和可规范化的 `GLMPanelLayout` 管理顺序、隐藏项及 JSON 持久化；`AppDelegate` 仍负责面板组装，但改为先注册卡片、再按可见顺序安装。卡片设置使用面板内原位 `NSTableView` 编辑器，支持拖动和上/下按钮；背景选择收进同一个原生 `NSMenu`，正常面板不直接拖拽卡片，避免与周期刷新重建和卡片内部交互冲突。

**Tech Stack:** Swift、AppKit（`NSPopover`、`NSStackView`、`NSTableView`、`NSMenu`）、Foundation `UserDefaults` / JSON、现有 `build.sh` 与离线 `--self-test` / 原生 preview 回归。

---

## 已确认范围与不可变边界

- 可配置卡片仅限 `.quota` 用量进度、`.peak` 峰谷状态、`.resetCards` 重置卡、`.usage` 用量情况、`.daily` 每日用量、`.mcp` MCP 工具。
- 页头、footer、更新提示/进度、连接套餐/解锁凭据恢复区不参与排序或隐藏；右上角「···」始终存在。
- 首版只支持显隐和纵向顺序，不做任意坐标、多列、卡片缩放或每卡片独立背景。
- 「隐藏」不等于现有「收起」；隐藏后仍照常获取数据，菜单栏 5H/7D、重新显示时的数据新鲜度及其他卡片不受影响。
- 允许全部隐藏；正常面板显示明确空态和恢复按钮，不能留下无法解释的空白。
- 恢复默认只重置卡片顺序与显隐，不修改背景样式、折叠状态、每日选中日或任何凭据。
- 预览和离线回归不得读真实凭据、联网、写生产偏好或执行真实重置卡/更新操作。
- 当前实现依据：`GlmUsage.swift` 的 `GLMPanelCard`（约 2065 行）、`AppDelegate.buildPanel()`（约 3578 行）、背景菜单（约 4637 行）和 preview 测试（约 4095 行起）。执行时以实际符号为准，不机械依赖行号。
- 开始实现前阅读 `@executing-plans`；真实原生拖拽/菜单验收使用 `@cua-driver-cli`。不要为了本功能把细节追加进已超预算的 `AGENTS.md`。

## 默认配置与目标菜单

```text
默认顺序：用量进度 → 峰谷状态 → 重置卡 → 用量情况 → 每日用量 → MCP 工具

···（toolTip / accessibilityLabel = 面板设置）
├─ 卡片显示与排序…
└─ 背景样式 ▸
   ├─ 纯色
   ├─ 经典毛玻璃
   └─ 液态玻璃（旧系统禁用并标注需 macOS 26+）
```

卡片设置页保留全部六行，隐藏项也留在列表中以便排序和重新开启。每行包含显示复选框、拖动手柄、上移和下移按钮；底部提供「恢复默认卡片布局」与「完成」。修改即时更新内存并保存，不提供语义含糊的「取消」；关闭 Popover 退出设置页但保留已修改布局。

---

### Task 1: 建立可迁移的卡片布局模型与独立源码边界

**Files:**
- Create: `PanelCustomization.swift`
- Modify: `build.sh:34-35`
- Modify: `GlmUsage.swift`（`GLMOfflineRegression.run()` 中背景样式断言之后）

**Step 1: 先写布局模型的失败回归**

在 `GLMOfflineRegression.run()` 加入以下断言。它们只使用内存数据和独立临时 `UserDefaults` suite，不碰生产偏好：

```swift
let defaultLayout = GLMPanelLayout.default
try expect(defaultLayout.order == GLMPanelCardID.allCases, "layout default order")
try expect(defaultLayout.visibleOrder == GLMPanelCardID.allCases, "layout default visibility")

var customLayout = defaultLayout
customLayout.setVisible(false, for: .mcp)
customLayout.move(.daily, direction: .up)
try expect(customLayout.visibleOrder == [.quota, .peak, .resetCards, .daily, .usage], "layout hide or move")
try expect(!customLayout.isVisible(.mcp) && customLayout.order.count == 6, "hidden card removed from editor order")

let roundTrip = GLMPanelLayout.decode(try customLayout.encoded())
try expect(roundTrip == customLayout, "layout JSON round trip")
try expect(GLMPanelLayout.decode(Data("bad".utf8)) == .default, "invalid layout did not fall back")

let legacyJSON = #"{"order":["usage","quota","daily","usage","futureCard"],"hidden":["mcp","futureCard"]}"#.data(using: .utf8)
let migrated = GLMPanelLayout.decode(legacyJSON)
try expect(migrated.order == [.peak, .resetCards, .usage, .quota, .daily, .mcp], "legacy order/new card insertion")
try expect(migrated.hidden == [.mcp], "unknown hidden ID retained")
try expect(migrated.isVisible(.peak) && migrated.isVisible(.resetCards), "missing new cards hidden by default")

var allHidden = GLMPanelLayout.default
for id in GLMPanelCardID.allCases { allHidden.setVisible(false, for: id) }
try expect(allHidden.visibleOrder.isEmpty && allHidden.order.count == 6, "all-hidden state rejected")

let suite = "GLMLayoutTest.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
customLayout.save(to: defaults)
try expect(GLMPanelLayout.load(from: defaults) == customLayout, "UserDefaults layout round trip")
```

**Step 2: 运行构建，确认测试因模型尚不存在而失败**

Run:

```bash
./build.sh
```

Expected: FAIL，Swift 编译报 `cannot find 'GLMPanelLayout' in scope`；不要先删断言来绕过。

**Step 3: 添加完整布局模型**

新建 `PanelCustomization.swift`，先只放以下纯模型，不引入 AppKit：

```swift
import Foundation

enum GLMPanelCardID: String, CaseIterable, Codable {
    case quota, peak, resetCards, usage, daily, mcp

    var title: String {
        switch self {
        case .quota: return "用量进度"
        case .peak: return "峰谷状态"
        case .resetCards: return "重置卡"
        case .usage: return "用量情况"
        case .daily: return "每日用量"
        case .mcp: return "MCP 工具"
        }
    }
}

enum GLMPanelMoveDirection {
    case up, down
    var offset: Int { self == .up ? -1 : 1 }
}

struct GLMPanelLayout: Equatable {
    private struct Stored: Codable {
        let order: [String]
        let hidden: [String]
    }

    static let defaultsKey = "panelCardLayout.v1"
    static let `default` = GLMPanelLayout(order: GLMPanelCardID.allCases, hidden: [])

    private(set) var order: [GLMPanelCardID]
    private(set) var hidden: Set<GLMPanelCardID>

    var visibleOrder: [GLMPanelCardID] { order.filter { !hidden.contains($0) } }

    func isVisible(_ id: GLMPanelCardID) -> Bool { !hidden.contains(id) }

    mutating func setVisible(_ visible: Bool, for id: GLMPanelCardID) {
        if visible { hidden.remove(id) } else { hidden.insert(id) }
    }

    mutating func move(_ id: GLMPanelCardID, direction: GLMPanelMoveDirection) {
        guard let index = order.firstIndex(of: id) else { return }
        move(id, to: index + direction.offset)
    }

    mutating func move(_ id: GLMPanelCardID, to destination: Int) {
        guard let source = order.firstIndex(of: id), !order.isEmpty else { return }
        let target = max(0, min(destination, order.count - 1))
        guard source != target else { return }
        let item = order.remove(at: source)
        order.insert(item, at: target)
    }

    static func normalized(order savedOrder: [GLMPanelCardID], hidden savedHidden: Set<GLMPanelCardID>) -> Self {
        var result: [GLMPanelCardID] = []
        for id in savedOrder where !result.contains(id) { result.append(id) }

        // 旧配置没有的新卡片按当前默认顺序的相对位置插入，而不是静默丢弃或一律追加末尾。
        for id in GLMPanelCardID.allCases where !result.contains(id) {
            guard let defaultIndex = GLMPanelCardID.allCases.firstIndex(of: id) else { continue }
            let successors = GLMPanelCardID.allCases[GLMPanelCardID.allCases.index(after: defaultIndex)...]
            if let next = successors.first(where: { result.contains($0) }), let index = result.firstIndex(of: next) {
                result.insert(id, at: index)
            } else {
                result.append(id)
            }
        }
        let known = Set(GLMPanelCardID.allCases)
        return Self(order: result, hidden: savedHidden.intersection(known))
    }

    static func decode(_ data: Data?) -> Self {
        guard let data, let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return .default }
        return normalized(order: stored.order.compactMap(GLMPanelCardID.init),
                          hidden: Set(stored.hidden.compactMap(GLMPanelCardID.init)))
    }

    func encoded() throws -> Data {
        let stored = Stored(order: order.map(\.rawValue),
                            hidden: GLMPanelCardID.allCases.filter { hidden.contains($0) }.map(\.rawValue))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(stored)
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        decode(defaults.data(forKey: defaultsKey))
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? encoded() else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
```

**Step 4: 让构建编译全部 Swift 源文件**

把 `build.sh` 的单文件编译命令替换为：

```bash
# GlmUsage.swift 保留唯一 top-level 入口；新增文件只能声明类型，不能增加第二个 main。
sources=("$DIR/GlmUsage.swift")
while IFS= read -r source; do
    sources+=("$source")
done < <(find "$DIR" -maxdepth 1 -name '*.swift' ! -name 'GlmUsage.swift' -print | sort)
swiftc -O -target arm64-apple-macos13.0 -o "$DIR/GlmUsage-bin" "${sources[@]}"
```

注意：这里使用 Bash 数组和进程替换，不依赖 macOS 默认 Bash 不具备的 `mapfile` 命令。

**Step 5: 运行模型和离线回归**

Run:

```bash
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
python3 -m unittest discover -s tests -p '*_test.py'
bash -n build.sh scripts/update.sh scripts/release.sh
```

Expected: 构建成功，`--self-test: PASS`，Python `OK`，Shell 检查无输出且退出码 0。

**Step 6: 提交**

```bash
git add PanelCustomization.swift GlmUsage.swift build.sh
git commit -m "feat: add persistent panel card layout model"
```

---

### Task 2: 按可见顺序组装卡片，并提供全部隐藏空态

**Files:**
- Modify: `GlmUsage.swift`（`AppDelegate` 属性、`buildPanel()`、preview 参数分流）
- Test: `GlmUsage.swift`（新增 `testCardSettings()` 的第一组断言）

**Step 1: 先添加原生布局回归入口和失败断言**

新增参数 `--preview-card-settings-test`，并将它加入 `preview`、`previewPopover`、`applicationDefined`、自动打开 Popover 和测试调度的所有现有参数集合。不得只加入其中一个集合。

在 `testCardSettings()` 中先建立公共查找函数和失败断言：

```swift
private func testCardSettings() {
    func fail(_ message: String) -> Never {
        fputs("GLM card settings test: FAIL \(message)\n", stderr); exit(1)
    }
    func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
    func cardOrder() -> [String] {
        panelRoot.arrangedSubviews.compactMap { view in
            guard view is GLMPanelCard, let raw = view.identifier?.rawValue else { return nil }
            return raw.replacingOccurrences(of: "GLMPanelCard.", with: "")
        }
    }
    let expectedDefault = GLMPanelCardID.allCases.map(\.rawValue)
    guard cardOrder() == expectedDefault else { fail("default card order \(cardOrder())"); return }
    // 后续任务在此追加菜单、显隐、排序、空态、键盘和滚动断言。
    print("GLM card settings test: PASS (default layout)")
    exit(0)
}
```

Run:

```bash
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-card-settings-test
```

Expected: FAIL `default card order []`，因为卡片尚未设置稳定 identifier；若测试未启动，先修参数分流，不得改成直接调用内部状态后假装 UI 测试通过。

**Step 2: 在 AppDelegate 持有布局，但预览不写生产偏好**

```swift
private var panelLayout = GLMPanelLayout.load()
private var showingCardSettings = false

private func persistPanelLayout() {
    if !preview { panelLayout.save() }
}
```

**Step 3: 注册卡片而不是立即固定加入 root**

在 `buildPanel()` 的正常内容分支开始处加入：

```swift
var cardViews: [GLMPanelCardID: GLMPanelCard] = [:]
func register(_ card: GLMPanelCard, as id: GLMPanelCardID) {
    card.identifier = NSUserInterfaceItemIdentifier("GLMPanelCard.\(id.rawValue)")
    cardViews[id] = card
}
```

保留六张卡片现有内容和构造顺序，仅将对应 `add(...)` 改为：

```swift
register(quotaCard, as: .quota)
register(peakCard, as: .peak)
register(cards, as: .resetCards)
register(usageCard, as: .usage)
register(dailyCard, as: .daily)
register(mcpCard, as: .mcp)
```

不要改写额度、峰谷、用卡确认、用量表格或每日图逻辑。

**Step 4: 统一安装可见卡片并实现空态**

在六张卡片构造完成后、创建 header 之前加入：

```swift
let visibleCards = panelLayout.visibleOrder.compactMap { cardViews[$0] }
if visibleCards.isEmpty {
    let emptyCard = GLMPanelCard()
    emptyCard.identifier = NSUserInterfaceItemIdentifier("GLMPanelEmptyState")
    addContent(label("卡片已全部隐藏，可通过右上角「···」恢复。", color: .secondaryLabelColor), to: emptyCard)
    let restore = button("恢复默认卡片布局", #selector(restoreDefaultPanelLayout))
    addContent(restore, to: emptyCard)
    add(emptyCard)
} else {
    for card in visibleCards { add(card) }
}
```

加入动作：

```swift
@objc private func restoreDefaultPanelLayout() {
    panelLayout = .default
    persistPanelLayout()
    showingCardSettings = false
    rebuildPanel()
}
```

更新提示、凭据恢复区仍放在卡片循环之前；不能把它们注册成可隐藏卡片。

**Step 5: 验证默认布局、隐藏顺序和空态**

在原生测试里通过 `panelLayout` 布置场景后调用真实 `rebuildPanel()`，断言：

```swift
panelLayout.setVisible(false, for: .mcp)
panelLayout.move(.daily, direction: .up)
rebuildPanel()
guard cardOrder() == ["quota", "peak", "resetCards", "daily", "usage"] else { fail("custom visible order") }
for id in GLMPanelCardID.allCases { panelLayout.setVisible(false, for: id) }
rebuildPanel()
guard allViews(panelController.view).contains(where: { $0.identifier?.rawValue == "GLMPanelEmptyState" }) else { fail("all-hidden empty state") }
restoreDefaultPanelLayout()
guard cardOrder() == expectedDefault else { fail("restore default") }
```

Run:

```bash
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-card-settings-test
```

Expected: 两套测试 PASS；默认卡片外观和默认顺序不变。

**Step 6: 提交**

```bash
git add GlmUsage.swift
git commit -m "feat: render configurable panel card visibility and order"
```

---

### Task 3: 用统一「···」菜单收拢卡片设置和背景样式

**Files:**
- Modify: `GlmUsage.swift`（header 按钮、原背景菜单方法、`popoverDidClose`）
- Test: `GlmUsage.swift`（`testCardSettings()`）

**Step 1: 先写菜单结构与背景回归**

在原生测试中增加：

```swift
let panelMenu = makePanelSettingsMenu()
guard panelMenu.items.map(\.title) == ["卡片显示与排序…", "背景样式"] else { fail("panel menu structure") }
guard let backgroundMenu = panelMenu.items[1].submenu else { fail("background submenu") }
guard backgroundMenu.items.map(\.title).contains("纯色") else { fail("solid background missing") }
for style in GLMPanelBackgroundStyle.allCases where style != .liquidGlass || Self.supportsLiquidGlass {
    guard let item = backgroundMenu.items.first(where: { $0.representedObject as? String == style.rawValue }) else { fail("background item \(style.rawValue)") }
    selectBackgroundStyle(item)
    guard backgroundStyle == style else { fail("background selection \(style.rawValue)") }
}
```

Run `./build.sh`；Expected: FAIL，报 `makePanelSettingsMenu` 不存在。

**Step 2: 实现可测试的菜单工厂和统一弹菜单路径**

用以下实现替换原 `showBackgroundStyleMenu(_:)`，保留 `selectBackgroundStyle(_:)` 与 `applyBackgroundStyle()` 不变：

```swift
private func makePanelSettingsMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false

    let cards = NSMenuItem(title: "卡片显示与排序…", action: #selector(showCardSettings), keyEquivalent: "")
    cards.target = self
    cards.isEnabled = !showingCardSettings
    menu.addItem(cards)

    let background = NSMenuItem(title: "背景样式", action: nil, keyEquivalent: "")
    let backgroundMenu = NSMenu()
    backgroundMenu.autoenablesItems = false
    for style in GLMPanelBackgroundStyle.allCases {
        let unavailable = style == .liquidGlass && !Self.supportsLiquidGlass
        let item = NSMenuItem(title: unavailable ? "液态玻璃（需 macOS 26+）" : style.title,
                              action: #selector(selectBackgroundStyle(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = style.rawValue
        item.state = style == backgroundStyle ? .on : .off
        item.isEnabled = !unavailable
        backgroundMenu.addItem(item)
    }
    background.submenu = backgroundMenu
    menu.addItem(background)
    return menu
}

@objc private func showPanelSettingsMenu(_ sender: NSButton) {
    let hadMonitors = localClickMonitor != nil || globalClickMonitor != nil
    if hadMonitors { removeClickMonitors() }
    makePanelSettingsMenu().popUp(positioning: nil, at: NSPoint(x: sender.bounds.maxX, y: -6), in: sender)
    if hadMonitors && popover.isShown { installClickMonitors() }
}
```

**Step 3: 替换页头图标并定义设置页进出动作**

将 `paintpalette` 按钮改为同尺寸 `ellipsis`，保持固定 24×24：

```swift
let settingsButton = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "面板设置") ?? NSImage(),
                              target: self, action: #selector(showPanelSettingsMenu(_:)))
settingsButton.isBordered = false
settingsButton.contentTintColor = .secondaryLabelColor
settingsButton.toolTip = "面板设置"
settingsButton.setAccessibilityLabel("面板设置")
settingsButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
settingsButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
header.addArrangedSubview(settingsButton)
```

增加：

```swift
@objc private func showCardSettings() {
    showingCardSettings = true
    rebuildPanel()
}

@objc private func finishCardSettings() {
    showingCardSettings = false
    rebuildPanel()
}
```

在 `popoverDidClose` 中设置 `showingCardSettings = false`，保留现有更新确认清理和 click monitor 清理。

**Step 4: 验证背景兼容规则和菜单动作**

Run:

```bash
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-card-settings-test
```

Expected: PASS；纯色/经典毛玻璃选择仍立即生效，液态玻璃旧系统禁用、降低透明度回退纯色，点击外部关闭 Popover 的 monitor 行为不回归。

**Step 5: 提交**

```bash
git add GlmUsage.swift
git commit -m "feat: unify panel customization and background menu"
```

---

### Task 4: 添加原位卡片设置页、显隐开关和键盘排序按钮

**Files:**
- Modify: `PanelCustomization.swift`
- Modify: `GlmUsage.swift`（`buildPanel()` 原位分支、原生测试）

**Step 1: 先写设置页交互失败断言**

在 `testCardSettings()` 中调用 `showCardSettings()` 并找到 `GLMCardSettingsView`，断言六行、隐藏 MCP、上移每日、完成后的实际卡片顺序：

```swift
showCardSettings()
guard showingCardSettings else { fail("settings did not open") }
guard let editor = allViews(panelController.view).compactMap({ $0 as? GLMCardSettingsView }).first else { fail("settings view missing") }
guard editor.layout.order.count == 6 else { fail("settings row count") }
editor.setVisible(false, for: .mcp)
editor.move(.daily, direction: .up)
finishCardSettings()
guard !showingCardSettings else { fail("settings did not close") }
guard cardOrder() == ["quota", "peak", "resetCards", "daily", "usage"] else { fail("settings changes not applied") }
showCardSettings()
guard let reopenedEditor = allViews(panelController.view).compactMap({ $0 as? GLMCardSettingsView }).first else { fail("reopened settings view missing") }
guard reopenedEditor !== editor else { fail("settings view was not rebuilt") }
guard reopenedEditor.layout.isVisible(.mcp) == false else { fail("hidden state lost on rebuild") }
finishCardSettings()
```

这里的 `setVisible` / `move` 是设置视图对按钮和拖放入口的内部转发，原生按钮事件断言在下一步补齐；不得只测模型而跳过实际视图。

**Step 2: 运行构建确认失败**

Run `./build.sh`；Expected: FAIL，`GLMCardSettingsView` 不存在。

**Step 3: 在 `PanelCustomization.swift` 添加完整设置视图**

保留已有模型，在文件末尾加入：

```swift
import AppKit

private let panelRowPasteboardType = NSPasteboard.PasteboardType.string

private final class GLMCardSettingRowView: NSTableCellView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let upButton = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "上移") ?? NSImage(), target: nil, action: nil)
    let downButton = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "下移") ?? NSImage(), target: nil, action: nil)
    var onToggle: ((Bool) -> Void)?
    var onMove: ((GLMPanelMoveDirection) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        checkbox.target = self; checkbox.action = #selector(toggle)
        checkbox.font = .systemFont(ofSize: 12)
        for button in [upButton, downButton] {
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        upButton.target = self; upButton.action = #selector(moveUpAction)
        downButton.target = self; downButton.action = #selector(moveDownAction)
        let handle = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动排序") ?? NSImage())
        handle.contentTintColor = .tertiaryLabelColor
        let spring = NSView()
        spring.setContentHuggingPriority(.init(1), for: .horizontal)
        spring.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [checkbox, spring, upButton, downButton, handle])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            handle.widthAnchor.constraint(equalToConstant: 20),
            handle.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(id: GLMPanelCardID, visible: Bool, first: Bool, last: Bool) {
        checkbox.title = id.title
        checkbox.state = visible ? .on : .off
        checkbox.setAccessibilityLabel("显示\(id.title)")
        checkbox.identifier = NSUserInterfaceItemIdentifier("CardToggle.\(id.rawValue)")
        upButton.isEnabled = !first
        downButton.isEnabled = !last
        upButton.setAccessibilityLabel("上移\(id.title)")
        downButton.setAccessibilityLabel("下移\(id.title)")
        upButton.identifier = NSUserInterfaceItemIdentifier("CardMoveUp.\(id.rawValue)")
        downButton.identifier = NSUserInterfaceItemIdentifier("CardMoveDown.\(id.rawValue)")
        toolTip = "拖动调整\(id.title)顺序"
    }

    @objc private func toggle(_ sender: NSButton) { onToggle?(sender.state == .on) }
    @objc private func moveUpAction() { onMove?(.up) }
    @objc private func moveDownAction() { onMove?(.down) }
}

final class GLMCardSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var layout: GLMPanelLayout
    private let onChange: (GLMPanelLayout) -> Void
    private let onDone: () -> Void
    private let table = NSTableView()

    init(layout: GLMPanelLayout, onChange: @escaping (GLMPanelLayout) -> Void, onDone: @escaping () -> Void) {
        self.layout = layout
        self.onChange = onChange
        self.onDone = onDone
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("card"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 34
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.registerForDraggedTypes([panelRowPasteboardType])
        table.draggingDestinationFeedbackStyle = .regular

        let title = NSTextField(labelWithString: "卡片显示与排序")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let hint = NSTextField(labelWithString: "勾选显示；拖动行或使用箭头调整顺序")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        let reset = NSButton(title: "恢复默认卡片布局", target: self, action: #selector(resetLayout))
        let done = NSButton(title: "完成", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        done.bezelStyle = .rounded
        done.controlSize = .regular
        let actions = NSStackView(views: [reset, NSView(), done])
        actions.orientation = .horizontal
        actions.alignment = .centerY

        let stack = GLMPanelStack()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [title, hint, table, actions] { stack.addArrangedSubview(view) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            table.widthAnchor.constraint(equalTo: stack.widthAnchor),
            table.heightAnchor.constraint(equalToConstant: CGFloat(GLMPanelCardID.allCases.count) * 36),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setVisible(_ visible: Bool, for id: GLMPanelCardID) {
        layout.setVisible(visible, for: id)
        commit()
    }

    func move(_ id: GLMPanelCardID, direction: GLMPanelMoveDirection) {
        layout.move(id, direction: direction)
        commit()
    }

    private func commit() {
        table.reloadData()
        onChange(layout)
    }

    @objc private func resetLayout() { layout = .default; commit() }
    @objc private func done() { onDone() }

    func numberOfRows(in tableView: NSTableView) -> Int { layout.order.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = layout.order[row]
        let view = GLMCardSettingRowView()
        view.configure(id: id, visible: layout.isVisible(id), first: row == 0, last: row == layout.order.count - 1)
        view.onToggle = { [weak self] visible in self?.setVisible(visible, for: id) }
        view.onMove = { [weak self] direction in self?.move(id, direction: direction) }
        return view
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(layout.order[row].rawValue, forType: panelRowPasteboardType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table,
              let raw = info.draggingPasteboard.string(forType: panelRowPasteboardType),
              GLMPanelCardID(rawValue: raw) != nil else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let raw = info.draggingPasteboard.string(forType: panelRowPasteboardType),
              let id = GLMPanelCardID(rawValue: raw),
              let source = layout.order.firstIndex(of: id) else { return false }
        let destination = source < row ? row - 1 : row
        layout.move(id, to: destination)
        commit()
        return true
    }
}
```

**Step 4: 在 `buildPanel()` 原位展示设置页**

将更新提示、凭据恢复区和六张卡片构造包进 `if showingCardSettings { ... } else { ... }`，设置分支为：

```swift
let editor = GLMCardSettingsView(layout: panelLayout,
    onChange: { [weak self] updated in
        guard let self else { return }
        self.panelLayout = updated
        self.persistPanelLayout()
    },
    onDone: { [weak self] in self?.finishCardSettings() })
add(editor)
```

header/footer 的创建和 `install` 保持公共路径；设置页不增加独立窗口，也不改变 footer 的刷新、更新或退出功能。

**Step 5: 通过真实按钮补齐测试**

使用上一完整代码中 row 的 checkbox/up/down 稳定 identifier（`CardToggle.*`、`CardMoveUp.*`、`CardMoveDown.*`），测试用 `NSButton.performClick(nil)` 触发，而不是只调用转发方法。再断言：

- 第一行上移和最后一行下移禁用；
- 复选框关闭后只隐藏对应卡片；
- 点击「完成」回到正常面板；
- 重开设置页保留内存布局；
- 关闭再打开 Popover 回到正常面板且布局不变；
- 在测试开始前保存 `let productionLayoutData = UserDefaults.standard.data(forKey: GLMPanelLayout.defaultsKey)`，结束时逐字节比较仍为原值，证明 preview 未写生产偏好（不能假定用户原先没有该配置）。

Run:

```bash
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-card-settings-test
```

Expected: PASS；设置页无独立窗口，开关/箭头/完成/重开全部通过。

**Step 6: 提交**

```bash
git add PanelCustomization.swift GlmUsage.swift
git commit -m "feat: add in-place card visibility and ordering editor"
```

---

### Task 5: 验证拖拽排序、动态键盘链和滚动钳制

**Files:**
- Modify: `GlmUsage.swift`（`GLMDailyUsageSectionView`、`buildPanel()`、`testCardSettings()`）
- Test: `GlmUsage.swift`（`testDailyInteraction()` 保持原断言）

**Step 1: 先写动态 key view 和滚动失败断言**

把每日图移到用量情况之前，并交换 MCP 的位置，断言 key view 链按可见顺序而非旧固定关系。隐藏每日图后断言链中不再包含其 `chartCanvas`。

在内容高度超过 Popover 可视高度时先把 `panelScroll` 滚到底，再隐藏每日/MCP 等大卡片，异步布局后断言：

```swift
let clip = panelScroll.contentView
let maxY = max(0, panelRoot.frame.height - clip.bounds.height)
guard clip.bounds.origin.y >= 0 && clip.bounds.origin.y <= maxY + 0.5 else { fail("scroll offset out of bounds after hide") }
```

Run `./build.sh && ./GlmUsage.app/Contents/MacOS/GlmUsage --preview-card-settings-test`；Expected: 键盘链断言 FAIL，证明旧硬编码 `usageSection → chartCanvas → mcpSection` 已被测试覆盖。

**Step 2: 暴露每日标题控件用于显式键盘链**

在 `GLMDailyUsageSectionView` 增加：

```swift
private(set) var toggleControl: NSView?
```

在创建现有 `toggle` 后赋值 `toggleControl = toggle`，不改变现有按钮样式或动作。

**Step 3: 按实际可见顺序连接 key view loop**

删除 `buildPanel()` 中固定的 `usageSection.nextKeyView = dailySection.chartCanvas`、`chartCanvas.nextKeyView = mcpSection` 和折叠分支，替换为：

```swift
var focusChain: [NSView] = []
for id in panelLayout.visibleOrder {
    switch id {
    case .usage:
        focusChain.append(usageSection)
    case .daily:
        if let toggle = dailySection.toggleControl { focusChain.append(toggle) }
        if dailyExpanded { focusChain.append(dailySection.chartCanvas) }
    case .mcp:
        focusChain.append(mcpSection)
    case .quota, .peak, .resetCards:
        break // 其他卡片内现有按钮继续由 AppKit 按几何与控件策略处理
    }
}
for (current, next) in zip(focusChain, focusChain.dropFirst()) {
    current.nextKeyView = next
}
```

每次重建都生成新视图；不要给已隐藏卡片或已移除的 chartCanvas 留链接。

**Step 4: 保持并验证滚动恢复**

保留 `buildPanel()` 末尾的 `savedOffset` 和异步布局恢复。其目标必须继续使用：

```swift
let maxY = max(0, root.frame.height - scroll.contentView.bounds.height)
let restoredY = min(maxY, max(0, savedOffset.y))
scroll.contentView.scroll(to: NSPoint(x: 0, y: restoredY))
scroll.reflectScrolledClipView(scroll.contentView)
```

排序且总高度不变时 offset 不变；隐藏导致内容变矮时钳制到新 `maxY`；打开/关闭设置页不漂移 Popover 锚点。

**Step 5: 验证模型拖动边界和真实 UI 路径**

在 `--self-test` 增加拖放目标位置等价模型断言：首项移到末尾、末项移到开头、同位置不变、越界钳制。在 `--preview-card-settings-test` 通过 row 的 pasteboard writer 与 table data source 验证拖放数据只接受本表六张卡，拒绝外部文本；真实鼠标拖拽由 Task 7 的 Cua 验收完成，不用直接调用 `acceptDrop` 冒充硬件拖拽验证。

Run（屏幕保持解锁，每个 GUI 测试进程之间至少间隔 5 秒）：

```bash
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-card-settings-test
sleep 5
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-popover-test
sleep 5
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-daily-test --preview-daily-gaps
```

Expected: 全部 PASS；每日图仍可通过 Tab 到达、左右键切日，Popover 原有几何/展开/重开断言不回归。

**Step 6: 提交**

```bash
git add GlmUsage.swift
git commit -m "fix: preserve panel keyboard and scroll behavior after reorder"
```

---

### Task 6: 更新当前用户说明、开发命令和架构事实

**Files:**
- Modify: `README.md`
- Modify: `docs/DEVELOPMENT.md`
- Modify: `docs/project/02-architecture.md`
- Modify: `docs/project/07-standards.md`
- Modify: `GlmUsage.swift`（如 self-test 最终 PASS 摘要需要补布局覆盖）

**Step 1: 更新用户入口**

在 `README.md` 将「面板背景」条目改为：

```markdown
- **面板自定义**：通过页头「···」统一设置卡片显隐、纵向顺序和面板背景；支持恢复默认卡片布局，选择保存在本机。背景可选纯色、经典毛玻璃或液态玻璃（macOS 26 及以上）。
```

不要把历史 PRD 的截图数字或旧默认顺序写成不可变规格；如更新截图，使用假数据且不包含真实邮箱。

**Step 2: 更新开发与架构事实**

在 `docs/DEVELOPMENT.md`：

- 文件表加入 `PanelCustomization.swift`，`GlmUsage.swift` 不再描述为“全部 Swift 源码”。
- 背景说明改为从「··· → 背景样式」进入。
- 调试命令加入：

```bash
# 卡片显隐/排序/统一菜单/空态/滚动与动态键盘链（其他 GUI 测试错开 ≥5s）
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-card-settings-test
```

在 `docs/project/02-architecture.md`：

- 应用形态改为 `GlmUsage.swift` 保留应用入口与面板组装，`PanelCustomization.swift` 管理布局模型和设置视图。
- 模块表加入 `GLMPanelLayout` 与 `GLMCardSettingsView`。
- 明确显隐不控制网络调度；固定更新/凭据恢复入口不属于可隐藏卡片。

在 `docs/project/07-standards.md` 将 `--preview-card-settings-test` 加入 Popover 交互验收，并注明 GUI 测试错开至少 5 秒、每日键盘测试需解锁。

**Step 3: 检查文档与实现一致**

Run:

```bash
rg -n "paintpalette|showBackgroundStyleMenu|面板背景|preview-card-settings-test|PanelCustomization" README.md docs GlmUsage.swift PanelCustomization.swift build.sh
```

Expected: 当前文档没有“页头直接点调色板”的旧说明；历史记录可保留，但不得冒充当前行为。所有新命令和文件名均真实存在。

**Step 4: 提交**

```bash
git add README.md docs/DEVELOPMENT.md docs/project/02-architecture.md docs/project/07-standards.md GlmUsage.swift
git commit -m "docs: document customizable panel cards"
```

---

### Task 7: 完整离线回归与真实原生交互验收

**Files:**
- Verify only: `GlmUsage.swift`, `PanelCustomization.swift`, `build.sh`, `README.md`, `docs/DEVELOPMENT.md`, `docs/project/02-architecture.md`, `docs/project/07-standards.md`
- Create only if defects are found: focused fix and matching regression in the existing files above

**Step 1: 运行完整离线门禁**

Run:

```bash
./build.sh
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test
python3 -m unittest discover -s tests -p '*_test.py'
bash -n build.sh scripts/update.sh scripts/release.sh
```

Expected: 构建成功；self-test / peak-test PASS；Python OK；Shell 语法检查退出码 0。失败则先补回归再修复，不降低旧断言。

**Step 2: 串行运行原生 GUI 回归**

确保屏幕解锁，且每条命令完全退出后再运行下一条：

```bash
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-popover-test
sleep 5
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-card-settings-test
sleep 5
./GlmUsage.app/Contents/MacOS/GlmUsage --preview-daily-test --preview-daily-gaps
```

Expected: 三个 PASS，无 `env-close` 被当作功能正确的替代证据；若发生环境关闭，报告中区分“恢复后通过”和“无干扰通过”。

**Step 3: 用 Cua 做真实菜单与拖拽冒烟**

按 `@cua-driver-cli` 操作假数据 preview，而非生产凭据面板：

1. 点击右上角「···」，确认菜单不被 click monitor 立即关闭。
2. 从「背景样式」切换纯色/经典毛玻璃，确认选中态和实际背景；液态玻璃仅在本机支持时验收。
3. 打开「卡片显示与排序…」，用鼠标拖动手柄交换两张卡片，再用上/下按钮调整另一张。
4. 隐藏全部卡片，确认固定页头/footer 与空态恢复按钮可见；恢复默认。
5. 关闭并重开 Popover，确认设置页退出且布局保留。
6. 使用 Tab、方向键和 VoiceOver 标签核对设置按钮、复选框、排序按钮及每日图可达。

Expected: 实际可见效果与状态一致，无独立设置窗口、无焦点抢夺、无卡片重叠或滚动空白。截图只含假数据。

**Step 4: 明确未覆盖范围并检查交付差异**

Run:

```bash
git status --short
git diff --check
git diff --stat
```

Expected: 无空白错误；只出现本计划相关文件。不得把离线 preview 结果表述为真实凭据、真实网络、macOS 13/14/15 全兼容或已部署验证。

真实部署、重启后生产偏好保留和 GUI 驻留冒烟需用户另行明确授权，并先确认没有其他实例并发运行；本计划不自动执行 `--once`、LaunchAgent 重载、发布或真实更新。

**Step 5: 提交最终修复（若 Step 1-4 无修改则跳过空提交）**

```bash
git add GlmUsage.swift PanelCustomization.swift build.sh README.md docs/DEVELOPMENT.md docs/project/02-architecture.md docs/project/07-standards.md
git commit -m "test: verify panel customization interactions"
```

---

## 完成定义

- 默认升级用户的六张卡片顺序、显隐和外观与当前版本一致。
- 一个固定「···」入口可进入卡片设置与背景子菜单；背景兼容/降低透明度规则不变。
- 六张卡可独立隐藏、拖动或通过按钮任意纵向排序；全部隐藏有可恢复空态。
- 布局跨面板重建、Popover 重开和应用重启保存；旧配置、新卡片、重复/未知 ID 和坏 JSON 都有确定行为。
- 隐藏只影响展示，不影响菜单栏、数据刷新、重置卡幂等规则或凭据恢复。
- 折叠状态与显隐独立，每日图选中状态不因重排丢失。
- 动态 key view、滚动钳制、Popover 尺寸/锚点、深浅外观及既有离线/原生测试全部通过。
- 当前 README、开发命令和架构文档同步更新；真实网络、部署和系统兼容证据按实际执行范围单独报告。
