import Foundation

/// Unweighted probe history for one stats-log window. This is deliberately separate from
/// the rolling health model and the menu's five-round latency: each has different semantics.
struct ProbeStatsWindow {
    static let maxReadings = Configuration.logging.maxProbeReadings
    private(set) var startedAt: TimeInterval
    private(set) var latencies: [Double] = []
    private(set) var latencySource: String?
    private(set) var routerLatencies: [Double] = []
    private(set) var total = 0
    private(set) var failed = 0
    private(set) var rejected = 0

    init(at: TimeInterval = BandwidthClock.now()) { startedAt = at }

    var hasMeasurements: Bool { !latencies.isEmpty || total > 0 }
    var loss: Double {
        guard !latencies.isEmpty else { return 1 }
        return total > 0 ? min(1, Double(failed + rejected) / Double(total)) : 0
    }

    mutating func recordWAN(_ verdict: Latency.EchoVerdict) {
        switch verdict {
        case .unmeasured: return
        case .wan(let ms): recordLatency(ms, source: LatencySource.icmp.rawValue)
        case .noReply: failed += 1
        case .onPath: rejected += 1
        }
        total += 1
    }

    mutating func recordLatency(_ ms: Double, source: String?) {
        guard let ms = finiteNonNeg(ms) else { return }
        pushLatency(ms, src: source, into: &latencies, source: &latencySource, limit: Self.maxReadings)
    }

    mutating func recordRouter(_ ms: Double) {
        routerLatencies.append(ms)
        if routerLatencies.count > Self.maxReadings { routerLatencies.removeFirst() }
    }
}
