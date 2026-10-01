import AppKit

/// Status item width that grows at once but shrinks only after the content has stayed narrower
/// for `shrinkAfter`, so neighbouring menu bar icons don't shift every time a digit drops.
struct StableWidth {
    static let shrinkAfter: TimeInterval = 30
    private(set) var width: Double = 0
    private var narrowerSince: TimeInterval?
    /// Widest content seen since `narrowerSince`; the width shrinks to this, not the latest value.
    private var narrowMax: Double = 0

    mutating func fit(_ content: Double, now: TimeInterval) -> Double {
        if content >= width {
            width = content; narrowerSince = nil
        } else if let since = narrowerSince {
            narrowMax = max(narrowMax, content)
            if now - since >= Self.shrinkAfter { width = narrowMax; narrowerSince = nil }
        } else {
            narrowerSince = now; narrowMax = content
        }
        return width
    }
}

/// Draws formatted measurements and owns the status item's layout and animation state.
final class StatusBarRenderer {
    private static let statusFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let statusAttrs: [NSAttributedString.Key: Any] = [.font: statusFont, .foregroundColor: NSColor.black]
    /// Gap between fields, with a separator line in the middle; an arrow hugs its number.
    private static let statusGap: CGFloat = 9
    private static let separatorAlpha: CGFloat = 0.3
    /// Health field while it calibrates. Right-aligned like "100%", so the % stays put and the
    /// spinner, drawn over the digit positions, is all that changes when the score arrives.
    static let calibratingText = "%"
    private static let spinnerFPS: TimeInterval = 12

    private let statusItem: NSStatusItem
    private var statusWidth = StableWidth()
    private var showThroughput = false
    private var spinnerTimer: Timer?
    private var spinnerPhase = 0
    private var lastStatus = (lat: "✕", health: "", down: "0B", up: "0B")

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        // Draw into a template image — status-item titles reflow/trim text.
        statusItem.button?.imagePosition = .imageOnly
    }

    deinit {
        spinnerTimer?.invalidate()
    }

    func render(lat: String, health: String, down: String, up: String,
                showThroughput: Bool, calibrating: Bool) {
        if self.showThroughput != showThroughput {
            // Hiding should narrow the item now, not after the usual shrink delay.
            statusWidth = StableWidth()
        }
        self.showThroughput = showThroughput
        setSpinning(calibrating)
        paintStatus(lat: lat, health: health, down: down, up: up)
    }

    /// Each field gets a slot wide enough for three digits and is right-aligned in it, so positions
    /// hold as digit counts change. Longer values (1363ms) widen their slot; `StableWidth` keeps
    /// the item from shrinking straight back.
    private func paintStatus(lat: String, health: String, down: String, up: String) {
        let item = statusItem
        guard let button = item.button else { return }
        lastStatus = (lat, health, down, up)
        var fields = [(lat, "999ms"), (health, "100%")]
        if showThroughput { fields += [(down + "↓", "999K↓"), (up + "↑", "999K↑")] }
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: Self.statusAttrs).width }
        let slots = fields.map { max(width($0.0), width($0.1)) }
        let content = ceil(slots.reduce(0, +) + Self.statusGap * CGFloat(fields.count - 1))
        let w = CGFloat(statusWidth.fit(Double(content), now: BandwidthClock.now()))
        let angle = CGFloat(spinnerPhase % 12) * 30
        let img = NSImage(size: NSSize(width: w, height: 18), flipped: false) { _ in
            var edge = w - content
            for (i, ((s, _), slot)) in zip(fields, slots).enumerated() {
                if i > 0 {
                    NSColor.black.withAlphaComponent(Self.separatorAlpha).setFill()
                    NSRect(x: (edge - Self.statusGap / 2).rounded() - 0.5, y: 4, width: 1, height: 10).fill()
                }
                edge += slot
                let x = edge - width(s)
                (s as NSString).draw(at: NSPoint(x: x, y: 2), withAttributes: Self.statusAttrs)
                if s == Self.calibratingText {
                    Self.drawSpinner(center: NSPoint(x: x - width("0"), y: 9), angle: angle)
                }
                edge += Self.statusGap
            }
            return true
        }
        img.isTemplate = true
        item.length = w
        button.image = img
    }

    /// A 270° arc; rotating `angle` animates it.
    private static func drawSpinner(center: NSPoint, angle: CGFloat) {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: 3.5, startAngle: -angle, endAngle: -angle + 270)
        arc.lineWidth = 1.4
        arc.lineCapStyle = .round
        NSColor.black.setStroke()
        arc.stroke()
    }

    private func setSpinning(_ on: Bool) {
        if on, spinnerTimer == nil {
            let t = Timer(timeInterval: 1 / Self.spinnerFPS, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.spinnerPhase += 1
                let s = self.lastStatus
                self.paintStatus(lat: s.lat, health: s.health, down: s.down, up: s.up)
            }
            RunLoop.main.add(t, forMode: .common)
            spinnerTimer = t
        } else if !on {
            spinnerTimer?.invalidate(); spinnerTimer = nil
        }
    }
}
