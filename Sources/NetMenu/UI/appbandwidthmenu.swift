import AppKit

/// The smallest descending prefix reaching 80% of combined download + upload,
/// with a hard cap of three even when traffic is spread across more apps.
struct TopBandwidthApps {
    static let targetShare = 0.8
    static let maxApps = 3
    let apps: [AppBandwidthUsage]
    let totalBytes: Double

    init(_ snapshot: AppBandwidthSnapshot) {
        let valid = snapshot.apps.filter {
            $0.downBytes.isFinite && $0.upBytes.isFinite && $0.downBytes >= 0 && $0.upBytes >= 0
                && $0.downBytes + $0.upBytes > 0
        }
        // Aggregate by resolved caller identity before ranking. Display aliases never merge apps.
        var grouped: [String: AppBandwidthUsage] = [:]
        for app in valid {
            let name = Self.cleanName(app.name)
            let key = app.id
            let previous = grouped[key]
            grouped[key] = AppBandwidthUsage(
                id: key, name: previous.map { min($0.name, name) } ?? name,
                downBytes: (previous?.downBytes ?? 0) + app.downBytes,
                upBytes: (previous?.upBytes ?? 0) + app.upBytes)
        }
        let ranked = grouped.values.sorted {
            let left = $0.downBytes + $0.upBytes, right = $1.downBytes + $1.upBytes
            if left != right { return left > right }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id < $1.id
        }
        // Socket accounting and physical-interface accounting differ slightly. Keep
        // unattributed physical bytes in the denominator, and never report over 100%.
        let attributed = ranked.reduce(0) { $0 + $1.downBytes + $1.upBytes }
        totalBytes = max(snapshot.totalBytes.isFinite ? snapshot.totalBytes : 0, attributed)
        apps = Self.coveringPrefix(ranked, total: totalBytes) { $0.downBytes + $0.upBytes }
    }

    /// Shared coverage policy for traffic and connection consumers.
    static func coveringPrefix<T>(_ ranked: [T], total: Double, weight: (T) -> Double) -> [T] {
        var selected: [T] = [], covered = 0.0
        for app in ranked.prefix(maxApps) {
            selected.append(app)
            covered += weight(app)
            if covered >= total * targetShare { break }
        }
        return selected
    }

    var share: Double {
        guard totalBytes > 0 else { return 0 }
        return apps.reduce(0) { $0 + $1.downBytes + $1.upBytes } / totalBytes
    }

    var reachedTarget: Bool { !apps.isEmpty && share >= Self.targetShare }

    var title: String { readout().title }

    func readout(stale: Bool = false) -> MenuReadout {
        let context = stale ? " (last sample)" : ""
        guard !apps.isEmpty else {
            return .row(.topApps, value: totalBytes > 0 ? "no attributed traffic" : "no traffic", context: context)
        }
        let names = apps.map { Self.menuName($0.name) }.joined(separator: ", ")
        // Round down so 79.9% never appears to have reached the 80% target.
        return .row(.topApps, value: names, qualifier: " (~\(Int(floor(share * 100)))%)", context: context)
    }

    static func cleanName(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func shortName(_ name: String, limit: Int = 18) -> String {
        let clean = cleanName(name)
        guard clean.count > limit else { return clean }
        return String(clean.prefix(max(0, limit - 1))) + "…"
    }

    /// A character limit alone does not bound wide glyphs. Keep three names within
    /// the existing menu's width, using the same system menu font as NSMenuItem.
    static func menuName(_ name: String) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        var shortened = shortName(name)
        while (shortened as NSString).size(withAttributes: attributes).width > 100 {
            if shortened.hasSuffix("…") { shortened.removeLast() }
            guard !shortened.isEmpty else { break }
            shortened.removeLast()
            shortened += "…"
        }
        return shortened
    }
}

/// Keep a useful list through transient sampler failures without presenting old data as live.
struct AppBandwidthDisplay {
    let config: MonitoringConfig
    init(config: MonitoringConfig = Configuration.monitoring) { self.config = config }
    static let updateInterval = AppBandwidthMonitor.sampleInterval
    static let freshFor = Configuration.monitoring.appFreshFor
    static let retainFor = Configuration.monitoring.appRetainFor
    static let initialFailureLimit = Configuration.monitoring.appInitialFailureLimit

    private var last: TopBandwidthApps?
    private var sampledAt: TimeInterval?
    private var failures = 0
    private var restarting = false
    private var published = MenuReadout.row(.topApps, value: "measuring…")
    private var publishedAt: TimeInterval?

    mutating func record(_ snapshot: AppBandwidthSnapshot?, at: TimeInterval) {
        if let snapshot {
            let top = TopBandwidthApps(snapshot)
            // Bytes with no attributable process are a missed reading, not an idle link.
            if !top.apps.isEmpty || top.totalBytes == 0 {
                last = top
                sampledAt = at
                failures = 0
                restarting = false
                return
            }
        }
        failures = min(failures + 1, config.appInitialFailureLimit)
    }

    mutating func restart(at: TimeInterval) {
        failures = 0
        restarting = true
        // Waking after a long sleep is normal calibration, not a collector failure.
        if let sampledAt, at - sampledAt > config.appRetainFor || at < sampledAt {
            last = nil
            self.sampledAt = nil
        }
    }

    /// Gate every visible change, including retry/recovery labels, to the same ten-second cadence.
    mutating func title(at: TimeInterval) -> String { readout(at: at).title }

    mutating func readout(at: TimeInterval) -> MenuReadout {
        let next = currentReadout(at: at)
        // Unchanged timer ticks must not move the deadline and delay a newly completed window.
        guard next != published else { return published }
        if let publishedAt, at >= publishedAt, at - publishedAt < config.appSampleInterval {
            return published
        }
        published = next
        publishedAt = at
        return published
    }

    private func currentReadout(at: TimeInterval) -> MenuReadout {
        if let last, let sampledAt {
            let age = at - sampledAt
            guard age >= 0, age <= config.appRetainFor else { return .row(.topApps, value: "unavailable") }
            if restarting || failures > 0 || age > config.appFreshFor {
                return last.readout(stale: true)
            }
            return last.readout()
        }
        return .row(.topApps, value: failures >= config.appInitialFailureLimit ? "unavailable" : "measuring…")
    }
}
