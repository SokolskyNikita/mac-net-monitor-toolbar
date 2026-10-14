import AppKit
import Testing
@testable import NetMenu

@Suite @MainActor struct MenuReadoutTests {
    @Test func statusImageDoesNotRetainItsRenderer() {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        var renderer: StatusBarRenderer? = StatusBarRenderer(statusItem: item)
        weak var released = renderer
        renderer?.render(lat: "20ms", health: "100%", down: "0B", up: "0B",
                         showThroughput: false, calibrating: false)
        renderer = nil
        #expect(released == nil)
    }

    @Test func updatesVisibleTextAndAccessibilityWhileKeepingDiagnosticTooltip() throws {
        let item = MenuReadoutItem(readout: .health(.health))
        let view = try #require(item.view)
        item.toolTip = "Detailed explanation"
        item.content = .health(.health, score: 49, parts: ["loss 0%", "jitter 67ms", "latency 727ms"])
        view.layoutSubtreeIfNeeded()
        let labels = view.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(labels.contains("49%"))
        #expect(labels.contains("Internet health"))
        #expect(labels.contains { $0.contains("RTT 727ms") })
        #expect(view.accessibilityLabel() == "Connection health: 49% (loss 0%, jitter 67ms, latency 727ms)")
        #expect(view.toolTip == "Detailed explanation")
        #expect(!item.isEnabled)
        #expect(item.title.isEmpty)
    }

    @Test func nativeMenuWidthFollowsTheReadoutInsteadOfItsUnwrappedDescription() {
        _ = NSApplication.shared
        let menu = NSMenu()
        let item = MenuReadoutItem(readout: .health(.health, score: 50, parts: ["ICMP", "loss 0%", "jitter 19ms", "latency 700ms"]))
        menu.addItem(item)
        menu.addItem(NSMenuItem(title: "Quit NetMenu", action: nil, keyEquivalent: "q"))
        #expect(menu.size.width == MenuReadoutView.width)
        item.content = .health(.health, score: 49, parts: ["HTTPS", "loss 10%", "jitter 190ms", "latency 1700ms"])
        #expect(menu.size.width == MenuReadoutView.width)
    }

    @Test func scanWarningFitsAndExposesFullAccessibleText() throws {
        let title = "⚠ Wi-Fi scans: Wi-Fi settings scans coincide with router delays."
        let item = MenuReadoutItem(readout: .detail(.warning, "Wi-Fi settings scans coincide with router delays."))
        let view = try #require(item.view)
        view.layoutSubtreeIfNeeded()
        #expect(view.accessibilityLabel() == title)
        for label in view.subviews.compactMap({ $0 as? NSTextField }) where !label.stringValue.isEmpty {
            #expect(label.frame.minX >= 0 && label.frame.maxX <= view.bounds.width)
            #expect(label.frame.maxY <= view.bounds.height)
        }
    }

    @Test func compactLabelsFitWithinTheReadout() throws {
        let rows: [MenuReadout] = [.row(.traffic, value: "680K↓ / 66K↑"), .row(.peak, value: "8.6M↓ / 2.0M↑"),
                                  .row(.topApps, value: "ChatGPT, git-remote-http", qualifier: " (~82%)")]
        for row in rows {
            let item = MenuReadoutItem(readout: row)
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

    @Test func layoutAndFontsDependOnKindEvenWhenLabelsAreRenamed() throws {
        for kind in [MenuReadoutKind.topApps, .connectionApps, .connections, .traffic] {
            var row = MenuReadout.row(kind, value: "A long app or connection description")
            row.heading = "Renamed: 99%"
            row.title = "Unrelated accessibility wording"
            let item = MenuReadoutItem(readout: row)
            let view = try #require(item.view)
            view.layoutSubtreeIfNeeded()
            let labels = view.subviews.compactMap { $0 as? NSTextField }
            let value = labels[1]
            let stacked = kind == .connections || kind == .connectionApps
            #expect(value.maximumNumberOfLines == (stacked ? 2 : 1))
            #expect(value.alignment == (stacked ? .left : .right))
            let expectedFont = kind == .topApps || kind == .connectionApps
                ? NSFont.systemFont(ofSize: 12) : NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            #expect(value.font == expectedFont)
            #expect(view.accessibilityLabel() == "Unrelated accessibility wording")
        }
    }

    @Test func healthColorUsesNumericScoreInsteadOfFormattedText() throws {
        var row = MenuReadout.health(.health, score: 49, parts: ["detail"])
        row.value = "Excellent"
        row.title = "100%"
        let item = MenuReadoutItem(readout: row)
        let view = try #require(item.view)
        let value = try #require(view.subviews.compactMap { $0 as? NSTextField }.dropFirst().first)
        #expect(value.stringValue == "Excellent")
        #expect(value.textColor != .labelColor)
        // Same text, changed semantics: the update must not be skipped.
        row.score = 100
        item.content = row
        #expect(value.stringValue == "Excellent")
        #expect(value.textColor == .labelColor)
    }
}
