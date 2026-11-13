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
