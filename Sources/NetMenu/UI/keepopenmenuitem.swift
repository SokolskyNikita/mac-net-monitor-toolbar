import AppKit

/// A button inside the menu handles clicks without invoking NSMenu's dismiss-on-action path.
/// The native item action remains available for keyboard menu selection.
final class KeepOpenMenuItem: NSMenuItem {
    private var row: KeepOpenMenuRow?

    override init(title: String, action: Selector?, keyEquivalent: String) {
        super.init(title: title, action: action, keyEquivalent: keyEquivalent)
        let row = KeepOpenMenuRow(title: title, target: self, action: #selector(activate))
        row.button.isEnabled = isEnabled
        row.updateAppearance()
        self.row = row
        view = row
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var title: String {
        didSet {
            row?.button.title = title
            row?.updateAppearance()
        }
    }

    override var isEnabled: Bool {
        didSet {
            row?.button.isEnabled = isEnabled
            row?.updateAppearance()
        }
    }

    override var toolTip: String? {
        didSet { row?.button.toolTip = toolTip }
    }

    @objc private func activate() {
        guard isEnabled, let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
}

/// AppKit does not draw the selection background for a menu item with a custom view.
private final class KeepOpenMenuRow: NSView {
    let button: NSButton
    private var hoverArea: NSTrackingArea?
    private var hovered = false

    init(title: String, target: AnyObject, action: Selector) {
        button = NSButton(title: title, target: target, action: action)
        super.init(frame: NSRect(x: 0, y: 0, width: MenuReadoutView.width, height: 24))
        autoresizingMask = [.width]
        button.frame = NSRect(x: 14, y: 2, width: bounds.width - 28, height: 20)
        button.autoresizingMask = [.width]
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.alignment = .left
        button.font = .menuFont(ofSize: 0)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        hovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        updateAppearance()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateAppearance()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hovered = false }
        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private var highlighted: Bool {
        button.isEnabled && (hovered || enclosingMenuItem?.isHighlighted == true)
    }

    func updateAppearance() {
        let color: NSColor = !button.isEnabled ? .disabledControlTextColor
            : highlighted ? .selectedMenuItemTextColor : .labelColor
        button.attributedTitle = NSAttributedString(string: button.title,
            attributes: [.font: button.font ?? NSFont.menuFont(ofSize: 0), .foregroundColor: color])
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
    }
}
