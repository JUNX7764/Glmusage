import AppKit

enum GLMQuotaHistoryGeometry {
    static func columns(width: CGFloat, height: CGFloat, count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let axis: CGFloat = min(20, max(0, width)), available = max(0, width - axis)
        func boundary(_ index: Int) -> CGFloat { index == 6 ? width : axis + available * CGFloat(index) / 6 }
        return (0..<min(count, 6)).map { CGRect(x: boundary($0), y: 0, width: boundary($0 + 1) - boundary($0), height: height) }
    }
}

final class GLMQuotaHistoryCanvas: NSView {
    var records: [GLMQuotaCycleRecord] = []
    var selected: UUID?
    var hover: UUID?
    var accent = NSColor.systemGreen
    var onHover: ((UUID?) -> Void)?
    var onClick: ((UUID) -> Void)?
    var onArrow: ((Int) -> Void)?
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true }
    override var isFlipped: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    private func record(at point: NSPoint) -> UUID? {
        let p = convert(point, from: nil)
        let frames = GLMQuotaHistoryGeometry.columns(width: bounds.width, height: bounds.height, count: records.count)
        return frames.firstIndex(where: { $0.contains(p) }).map { records[$0].id }
    }
    override func mouseMoved(with event: NSEvent) { let id = record(at: event.locationInWindow); hover = id; needsDisplay = true; onHover?(id) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true; onHover?(nil) }
    override func mouseDown(with event: NSEvent) {
        guard let id = record(at: event.locationInWindow) else { return }
        window?.makeFirstResponder(self); selected = id; needsDisplay = true; onClick?(id)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 { onArrow?(-1) }
        else if event.keyCode == 124 { onArrow?(1) }
        else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let frames = GLMQuotaHistoryGeometry.columns(width: bounds.width, height: bounds.height, count: records.count)
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
        ("100%" as NSString).draw(at: NSPoint(x: 0, y: bounds.height - 13), withAttributes: labelAttributes)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "MM/dd"
        for (i, rect) in frames.enumerated() {
            let record = records[i], highlighted = (hover ?? selected) == record.id
            if record.end == nil || highlighted { accent.withAlphaComponent(highlighted ? 0.11 : 0.05).setFill(); rect.insetBy(dx: 1, dy: 0).fill() }
            let baseline: CGFloat = 17, chartHeight = max(0, rect.height - baseline - 4)
            let center = rect.midX
            NSColor.secondaryLabelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: NSRect(x: center - 8, y: baseline, width: 6, height: chartHeight), xRadius: 2, yRadius: 2).fill()
            let usedHeight = chartHeight * CGFloat(max(0, min(100, record.lastObservation.usedPercent))) / 100
            accent.withAlphaComponent(highlighted ? 1 : 0.72).setFill()
            NSBezierPath(roundedRect: NSRect(x: center + 2, y: baseline, width: 6, height: max(2, usedHeight)), xRadius: 2, yRadius: 2).fill()
            let text = formatter.string(from: record.firstObservedAt) + (record.startKind == .firstObserved ? "*" : "")
            let size = (text as NSString).size(withAttributes: labelAttributes)
            (text as NSString).draw(at: NSPoint(x: center - size.width / 2, y: 1), withAttributes: labelAttributes)
        }
    }
}

final class GLMQuotaHistorySectionView: NSStackView {
    let canvas = GLMQuotaHistoryCanvas()
    private let firstLine = NSTextField(labelWithString: "")
    private let secondLine = NSTextField(labelWithString: "")
    private var records: [GLMQuotaCycleRecord]
    private var browser: GLMQuotaHistoryBrowser
    private let changed: (GLMQuotaHistoryBrowser, Bool) -> Void
    init(records: [GLMQuotaCycleRecord], browser: GLMQuotaHistoryBrowser, accent: NSColor,
         pending: Bool, status: String?, changed: @escaping (GLMQuotaHistoryBrowser, Bool) -> Void) {
        self.records = records; self.browser = browser; self.changed = changed
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 3; translatesAutoresizingMaskIntoConstraints = false
        let range = browser.visibleRange(records)
        let controls = NSStackView(); controls.orientation = .horizontal; controls.alignment = .centerY; controls.spacing = 5
        let legend = NSTextField(labelWithString: "上限 / 已用"); legend.font = .systemFont(ofSize: 10); legend.textColor = .secondaryLabelColor
        controls.addArrangedSubview(legend)
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal); controls.addArrangedSubview(spacer)
        for (title, selector) in [("‹", #selector(older)), ((browser.pageAnchorID == nil ? "最近" : "历史") + "\(range.count)轮", #selector(latest)), ("›", #selector(newer)), ("更早", #selector(earlier))] {
            let b = NSButton(title: title, target: self, action: selector); b.isBordered = false; b.font = .systemFont(ofSize: 11); controls.addArrangedSubview(b)
        }
        addArrangedSubview(controls); controls.widthAnchor.constraint(equalTo: widthAnchor).isActive = true; controls.heightAnchor.constraint(equalToConstant: 22).isActive = true
        canvas.records = Array(records[range]); canvas.selected = browser.selectedCycleID ?? records.last?.id; canvas.accent = accent
        canvas.setAccessibilityElement(true); canvas.setAccessibilityRole(.group)
        canvas.setAccessibilityLabel("额度周期回顾，使用左右方向键选择")
        canvas.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(canvas); canvas.widthAnchor.constraint(equalTo: widthAnchor).isActive = true; canvas.heightAnchor.constraint(equalToConstant: 78).isActive = true
        for line in [firstLine, secondLine] {
            line.font = .systemFont(ofSize: 10); line.textColor = .secondaryLabelColor; line.lineBreakMode = .byTruncatingTail
            addArrangedSubview(line); line.widthAnchor.constraint(equalTo: widthAnchor).isActive = true; line.heightAnchor.constraint(equalToConstant: 14).isActive = true
        }
        if records.isEmpty {
            firstLine.stringValue = "从首次成功读取周额度后开始记录"; secondLine.stringValue = status ?? "历史按套餐连接保存；更换 Key 不自动合并"
        } else {
            show(browser.selectedCycleID ?? records.last?.id, pending: pending, status: status)
        }
        canvas.onHover = { [weak self] id in guard let self else { return }; self.show(id ?? self.browser.selectedCycleID ?? self.records.last?.id, pending: pending, status: status) }
        canvas.onClick = { [weak self] id in guard let self else { return }; self.browser.select(id); self.show(id, pending: pending, status: status); self.changed(self.browser, false) }
        canvas.onArrow = { [weak self] direction in
            guard let self else { return }
            let oldRange = self.browser.visibleRange(self.records)
            self.browser.move(direction, records: self.records)
            let changedPage = oldRange != self.browser.visibleRange(self.records)
            self.canvas.selected = self.browser.selectedCycleID
            self.canvas.needsDisplay = true
            self.show(self.browser.selectedCycleID, pending: pending, status: status)
            self.changed(self.browser, changedPage)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func show(_ id: UUID?, pending: Bool, status: String?) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        let lines = GLMQuotaCycleDetails.lines(record)
        firstLine.stringValue = lines.0; secondLine.stringValue = lines.1
        let suffix = [pending ? "窗口变化待确认" : nil, status].compactMap { $0 }.joined(separator: " · ")
        if !suffix.isEmpty { firstLine.stringValue = suffix + " · " + lines.0 }
        firstLine.toolTip = lines.0 + " · 历史按套餐连接保存，更换 Key 不自动合并"; secondLine.toolTip = lines.1 + (suffix.isEmpty ? "" : " · " + suffix)
        canvas.setAccessibilityLabel("额度周期回顾")
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateStyle = .medium; formatter.timeStyle = .medium
        let observationTime = "最后成功观测：" + formatter.string(from: record.lastObservation.observedAt)
        secondLine.toolTip = (secondLine.toolTip ?? "") + " · " + observationTime
        canvas.setAccessibilityValue(lines.0 + "，" + lines.1 + "，" + observationTime + (suffix.isEmpty ? "" : "，" + suffix))
    }
    @objc private func older() { browser.pageOlder(records); changed(browser, true) }
    @objc private func newer() { browser.pageNewer(records); changed(browser, true) }
    @objc private func latest() { browser.pageAnchorID = nil; browser.selectedCycleID = records.last?.id; changed(browser, true) }
    @objc private func earlier() { browser.loadEarlier(); browser.pageOlder(records); changed(browser, true) }
}
