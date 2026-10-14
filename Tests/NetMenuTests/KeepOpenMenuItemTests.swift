import AppKit
import Testing
@testable import NetMenu

@Suite @MainActor struct KeepOpenMenuItemTests {
    private final class Target: NSObject {
        var clicks = 0
        @objc func clicked(_ sender: Any?) { clicks += 1 }
    }

    @Test func embeddedButtonInvokesActionAndReflectsRunningState() throws {
        _ = NSApplication.shared
        let target = Target()
        let menu = NSMenu()
        let item = KeepOpenMenuItem(title: "Run speed test", action: #selector(Target.clicked(_:)), keyEquivalent: "")
        item.target = target
        menu.addItem(item)
        let button = try #require(item.view?.subviews.first as? NSButton)
        button.performClick(nil)
        #expect(target.clicks == 1)
        #expect(item.menu === menu)
        item.title = "Cancel speed test"
        item.toolTip = "Test budget"
        #expect(button.title == "Cancel speed test")
        #expect(button.toolTip == "Test budget")
        button.performClick(nil)
        #expect(target.clicks == 2)
        item.isEnabled = false
        #expect(!button.isEnabled)
        button.performClick(nil)
        #expect(target.clicks == 2)
        #expect(menu.size.width == MenuReadoutView.width)
    }
}
