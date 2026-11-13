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

import AppKit

private let panelRowPasteboardType = NSPasteboard.PasteboardType.string

final class GLMCardSettingRowView: NSTableCellView {
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
    let table = NSTableView()
    private var resetButton: NSButton!
    private var backButton: NSButton!
    private var doneButton: NSButton!

    /// 打开设置页时的初始焦点视图：Space 等按键应作用于设置控件，而不是残留的上一次点击目标。
    var initialKeyView: NSView { table }

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
        // 「返回」与「完成」同为退出设置页回面板：改动经 onChange 即时生效，无可丢弃的待定修改，
        // 因此语义相同；保留两个出口是降低「完成=提交」的心理负担，视觉上用默认灰底区别于蓝色主按钮。
        let back = NSButton(title: "返回", target: self, action: #selector(back))
        back.bezelStyle = .rounded
        back.controlSize = .regular
        let done = NSButton(title: "完成", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        done.bezelStyle = .rounded
        done.controlSize = .regular
        self.resetButton = reset
        self.backButton = back
        self.doneButton = done
        let actions = NSStackView(views: [reset, NSView(), back, done])
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wireKeyLoop()
    }

    /// 设置页 key view loop：表格 → 每行复选框 → 上移/下移 → 恢复默认 → 返回 → 完成 → 回到表格。
    /// 不接线时 Space 会落到进入设置页前的残留焦点（如「···」按钮），把菜单再弹出来并关掉 transient Popover。
    private func wireKeyLoop() {
        var chain: [NSView] = [table]
        for row in 0..<numberOfRows(in: table) {
            guard let rowView = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? GLMCardSettingRowView else { continue }
            chain.append(rowView.checkbox)
            chain.append(rowView.upButton)
            chain.append(rowView.downButton)
        }
        chain.append(resetButton)
        chain.append(backButton)
        chain.append(doneButton)
        for (current, next) in zip(chain, chain.dropFirst()) {
            current.nextKeyView = next
        }
        doneButton.nextKeyView = table
    }

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
        wireKeyLoop()
        onChange(layout)
    }

    @objc private func resetLayout() { layout = .default; commit() }
    @objc private func back() { onDone() }
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
