import AppKit

/// Read-only content with normal contrast, rather than the disabled-command appearance.
/// Keep native titles empty: AppKit otherwise sizes the menu for their unwrapped text.
/// The custom view retains the full description for accessibility and tooltips.
final class MenuReadoutItem: NSMenuItem {
    enum Style { case health, local, compact, result }
    private var readout: MenuReadoutView?

    init(title: String, style: Style) {
        self.readoutTitle = title
        super.init(title: "", action: nil, keyEquivalent: "")
        let content = MenuReadoutView(style: style)
        readout = content
        view = content
        isEnabled = false
        content.update(title)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var readoutTitle: String {
        didSet {
            readout?.update(readoutTitle)
            if let toolTip { readout?.toolTip = toolTip }
        }
    }

    override var toolTip: String? {
        didSet { readout?.toolTip = toolTip ?? readoutTitle }
    }
}

final class MenuReadoutView: NSView {
    static let width: CGFloat = 358
    private static let warningColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 1, green: 0.69, blue: 0.29, alpha: 1)
        }
        return NSColor(calibratedRed: 0.65, green: 0.32, blue: 0.02, alpha: 1)
    }
    private let style: MenuReadoutItem.Style
    private let heading = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var lastTitle: String?
    private var stacked = false

    init(style: MenuReadoutItem.Style) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 22))
        for label in [heading, value, detail] {
            label.isSelectable = false
            label.isEditable = false
            label.drawsBackground = false
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        heading.font = .systemFont(ofSize: 12, weight: .medium)
        heading.textColor = .secondaryLabelColor
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        value.textColor = .labelColor
        value.alignment = .right
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byWordWrapping
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func update(_ title: String) {
        guard title != lastTitle else { return }
        lastTitle = title
        toolTip = title
        setAccessibilityLabel(title)
        let split = title.range(of: ": ")
        let name = split.map { String(title[..<$0.lowerBound]) } ?? ""
        let body = split.map { String(title[$0.upperBound...]) } ?? title
        value.textColor = .labelColor
        switch style {
        case .health, .local:
            heading.stringValue = style == .health ? "Internet health" : "Local router"
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
            heading.textColor = .labelColor
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            if let percent = body.firstIndex(of: "%"), let score = Int(body[..<percent]) {
                value.stringValue = "\(score)%"
                value.textColor = score < 95 ? Self.warningColor : .labelColor
                let rest = String(body[body.index(after: percent)...]).trimmingCharacters(in: .whitespaces)
                detail.stringValue = rest.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                    .replacingOccurrences(of: ", ", with: " · ")
                    .replacingOccurrences(of: "latency ", with: "RTT ")
            } else {
                value.stringValue = "—"
                detail.stringValue = body
            }
        case .compact:
            let names = ["Throughput": "Traffic", "Peak this connection": "Peak", "Top apps": "Top apps"]
            heading.stringValue = split == nil ? title : (names[name] ?? (name.hasPrefix("Top apps") ? "Top apps" : name))
            value.stringValue = split == nil ? "" : body
            if name.hasPrefix("Top apps"), let suffix = name.range(of: " (~") {
                heading.stringValue += " " + name[suffix.lowerBound...].trimmingCharacters(in: .whitespaces)
            }
            // Application names should use proportional text; reserve tabular digits for measurements.
            value.font = (name.hasPrefix("Top apps") || name.hasPrefix("Top conn.")) ? .systemFont(ofSize: 12) : .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            detail.stringValue = ""
            stacked = name == "Connections" || name.hasPrefix("Top conn. consumers")
            value.alignment = stacked ? .left : .right
            value.maximumNumberOfLines = stacked ? 2 : 1
            value.lineBreakMode = stacked ? .byWordWrapping : .byTruncatingTail
        case .result:
            heading.stringValue = name.isEmpty ? "Speed test" : name
            value.stringValue = ""
            detail.stringValue = body
            detail.font = .systemFont(ofSize: 12, weight: .medium)
            detail.textColor = .labelColor
        }
        // Reserve a second line only when the text actually wraps.
        let textWidth = Self.width - 28
        let height: CGFloat
        if style == .health || style == .local {
            height = 28 + textHeight(detail, width: textWidth)
        } else if style == .result {
            height = 36 + textHeight(detail, width: textWidth)
        } else if stacked {
            height = 24 + textHeight(value, width: textWidth)
        } else {
            height = 22
        }
        setFrameSize(NSSize(width: Self.width, height: height))
        needsLayout = true
    }

    private func textHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        guard !label.stringValue.isEmpty else { return 0 }
        return ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100)).height ?? 14)
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 14, contentWidth = bounds.width - 2 * inset
        if style == .health || style == .local {
            heading.frame = NSRect(x: inset, y: 3, width: contentWidth - 70, height: 20)
            value.frame = NSRect(x: bounds.width - inset - 65, y: 0, width: 65, height: 24)
            detail.frame = NSRect(x: inset, y: 24, width: contentWidth, height: bounds.height - 28)
        } else if style == .result {
            heading.frame = NSRect(x: inset, y: 8, width: contentWidth, height: 16)
            value.frame = .zero
            detail.frame = NSRect(x: inset, y: 26, width: contentWidth, height: bounds.height - 36)
        } else if stacked {
            heading.frame = NSRect(x: inset, y: 2, width: contentWidth, height: 17)
            value.frame = NSRect(x: inset, y: 20, width: contentWidth, height: bounds.height - 24)
            detail.frame = .zero
        } else if value.stringValue.isEmpty {
            heading.frame = NSRect(x: inset, y: 3, width: contentWidth, height: 17)
            value.frame = .zero
            detail.frame = .zero
        } else {
            let labelWidth = min(135, ceil(heading.intrinsicContentSize.width) + 8)
            heading.frame = NSRect(x: inset, y: 3, width: labelWidth, height: 17)
            value.frame = NSRect(x: inset + labelWidth + 12, y: 3, width: contentWidth - labelWidth - 12, height: 17)
            detail.frame = .zero
        }
    }
}
