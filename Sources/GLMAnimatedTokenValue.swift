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

    override func accessibilityValue() -> String? { exactText }

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
