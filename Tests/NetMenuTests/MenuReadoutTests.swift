import AppKit
import Testing
@testable import NetMenu

@Suite @MainActor struct MenuReadoutTests {
    @Test func updatesVisibleTextAndAccessibilityWhileKeepingDiagnosticTooltip() throws {
        let item = MenuReadoutItem(title: "Connection health: measuring…", style: .health)
        let view = try #require(item.view)
        item.toolTip = "Detailed explanation"
        item.readoutTitle = "Connection health: 49% (loss 0%, jitter 67ms, latency 727ms)"
        view.layoutSubtreeIfNeeded()
        let labels = view.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(labels.contains("49%"))
        #expect(labels.contains("Internet health"))
        #expect(labels.contains { $0.contains("RTT 727ms") })
        #expect(view.accessibilityLabel() == item.readoutTitle)
        #expect(view.toolTip == "Detailed explanation")
        #expect(!item.isEnabled)
        #expect(item.title.isEmpty)
    }

    @Test func nativeMenuWidthFollowsTheReadoutInsteadOfItsUnwrappedDescription() {
        _ = NSApplication.shared
        let menu = NSMenu()
        let item = MenuReadoutItem(title: "Connection health: 50% (ICMP, loss 0%, jitter 19ms, latency 700ms)", style: .health)
        menu.addItem(item)
        menu.addItem(NSMenuItem(title: "Quit NetMenu", action: nil, keyEquivalent: "q"))
        #expect(menu.size.width == MenuReadoutView.width)
        item.readoutTitle = "Connection health: 49% (HTTPS, loss 10%, jitter 190ms, latency 1700ms)"
        #expect(menu.size.width == MenuReadoutView.width)
    }

    @Test func compactLabelsFitWithinTheReadout() throws {
        for title in ["Throughput: 680K↓ / 66K↑", "Peak this connection: 8.6M↓ / 2.0M↑",
                      "Top apps (~82%): ChatGPT, git-remote-http"] {
            let item = MenuReadoutItem(title: title, style: .compact)
            let view = try #require(item.view)
            view.layoutSubtreeIfNeeded()
            let labels = view.subviews.compactMap { $0 as? NSTextField }.filter { !$0.stringValue.isEmpty }
            for label in labels {
                #expect(label.frame.minX >= 0 && label.frame.maxX <= view.bounds.width)
                let width = (label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width
                #expect(width <= label.frame.width)
            }
        }
    }
}
