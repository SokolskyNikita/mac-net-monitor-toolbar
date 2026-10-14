import AppKit

/// A button inside the menu handles clicks without invoking NSMenu's dismiss-on-action path.
/// The native item action remains available for keyboard menu selection.
final class KeepOpenMenuItem: NSMenuItem {
    private var button: NSButton?

    override init(title: String, action: Selector?, keyEquivalent: String) {
        super.init(title: title, action: action, keyEquivalent: keyEquivalent)
        let row = NSView(frame: NSRect(x: 0, y: 0, width: MenuReadoutView.width, height: 24))
        row.autoresizingMask = [.width]
        let button = NSButton(title: title, target: self, action: #selector(activate))
        button.frame = NSRect(x: 14, y: 2, width: row.bounds.width - 28, height: 20)
        button.autoresizingMask = [.width]
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.alignment = .left
        button.font = .menuFont(ofSize: 0)
        button.isEnabled = isEnabled
        row.addSubview(button)
        self.button = button
        view = row
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var title: String {
        didSet { button?.title = title }
    }

    override var isEnabled: Bool {
        didSet { button?.isEnabled = isEnabled }
    }

    override var toolTip: String? {
        didSet { button?.toolTip = toolTip }
    }

    @objc private func activate() {
        guard isEnabled, let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
}
