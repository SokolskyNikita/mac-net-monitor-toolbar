import AppKit

/// Semantic row types select layout; display wording is never used as a type tag.
enum MenuReadoutKind {
    case health, local, traffic, peak, topApps, connections, connectionApps, message, result

    var isHealth: Bool { self == .health || self == .local }
    var isDetailed: Bool { self == .result }
    var isStacked: Bool { self == .connections || self == .connectionApps }
    var usesProportionalValue: Bool { self == .topApps || self == .connectionApps }
    var label: String {
        switch self {
        case .health: return "Connection health"
        case .local: return "Local health"
        case .traffic: return "Throughput"
        case .peak: return "Peak this connection"
        case .topApps: return "Top apps"
        case .connections: return "Connections"
        case .connectionApps: return "Top conn. consumers"
        case .result: return "Speed test"
        case .message: return ""
        }
    }
    var heading: String {
        switch self {
        case .health: return "Internet health"
        case .local: return "Local router"
        case .traffic: return "Traffic"
        case .peak: return "Peak"
        default: return label
        }
    }
}

/// Full text remains available to CLI callers, accessibility and tooltips.
struct MenuReadout: Equatable {
    var kind: MenuReadoutKind
    var heading: String
    var value: String = ""
    var detail: String = ""
    var score: Int? = nil
    var title: String

    static func row(_ kind: MenuReadoutKind, value: String, qualifier: String = "", context: String = "") -> Self {
        Self(kind: kind, heading: kind.heading + qualifier, value: value,
             title: kind.label + context + qualifier + ": " + value)
    }

    static func message(_ text: String) -> Self {
        Self(kind: .message, heading: text, title: text)
    }

    static func detail(_ kind: MenuReadoutKind, _ text: String) -> Self {
        Self(kind: kind, heading: kind.heading, detail: text,
             title: kind == .result ? text : kind.label + ": " + text)
    }

    static func health(_ kind: MenuReadoutKind, score: Int? = nil, parts: [String] = [], status: String = "measuring…") -> Self {
        guard let score else {
            return Self(kind: kind, heading: kind.heading, value: "—", detail: status,
                        title: kind.label + ": " + status)
        }
        return Self(kind: kind, heading: kind.heading, value: "\(score)%",
                    detail: parts.joined(separator: ", ").replacingOccurrences(of: ", ", with: " · ")
                        .replacingOccurrences(of: "latency ", with: "RTT "),
                    score: score, title: "\(kind.label): \(score)% (\(parts.joined(separator: ", ")))")
    }
}

/// Read-only content with normal contrast, rather than the disabled-command appearance.
/// Keep native titles empty: AppKit otherwise sizes the menu for their unwrapped text.
/// The custom view retains the full description for accessibility and tooltips.
final class MenuReadoutItem: NSMenuItem {
    private var readout: MenuReadoutView?

    init(readout: MenuReadout) {
        self.content = readout
        super.init(title: "", action: nil, keyEquivalent: "")
        let content = MenuReadoutView()
        self.readout = content
        view = content
        isEnabled = false
        content.update(readout)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var content: MenuReadout {
        didSet {
            readout?.update(content)
            if let toolTip { readout?.toolTip = toolTip }
        }
    }

    override var toolTip: String? {
        didSet { readout?.toolTip = toolTip ?? content.title }
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
    private var kind = MenuReadoutKind.message
    private let heading = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var lastReadout: MenuReadout?
    private var stacked = false

    init() {
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

    func update(_ content: MenuReadout) {
        guard content != lastReadout else { return }
        lastReadout = content
        kind = content.kind
        stacked = kind.isStacked
        toolTip = content.title
        setAccessibilityLabel(content.title)
        heading.stringValue = content.heading
        value.stringValue = content.value
        detail.stringValue = content.detail
        heading.font = .systemFont(ofSize: 12, weight: .medium)
        heading.textColor = .secondaryLabelColor
        value.textColor = .labelColor
        value.alignment = stacked ? .left : .right
        value.maximumNumberOfLines = stacked ? 2 : 1
        value.lineBreakMode = stacked ? .byWordWrapping : .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        if kind.isHealth {
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
            heading.textColor = .labelColor
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            if let score = content.score, score < 95 { value.textColor = Self.warningColor }
        } else if kind.isDetailed {
            detail.font = .systemFont(ofSize: 12, weight: .medium)
            detail.textColor = .labelColor
        } else {
            value.font = kind.usesProportionalValue ? .systemFont(ofSize: 12)
                : .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        // Reserve a second line only when the text actually wraps.
        let textWidth = Self.width - 28
        let height: CGFloat
        if kind.isHealth {
            height = 28 + textHeight(detail, width: textWidth)
        } else if kind.isDetailed {
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
        if kind.isHealth {
            heading.frame = NSRect(x: inset, y: 3, width: contentWidth - 70, height: 20)
            value.frame = NSRect(x: bounds.width - inset - 65, y: 0, width: 65, height: 24)
            detail.frame = NSRect(x: inset, y: 24, width: contentWidth, height: bounds.height - 28)
        } else if kind.isDetailed {
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
