// Connection health: one 0–100 score from packet loss, latency stability, and latency level.
//
//   health = 100 × (1 − loss penalty) × (1 − jitter penalty) × (1 − latency penalty)
//
// Penalties multiply, so one bad dimension sinks the score even when the others are fine.
// Anything within Zoom's recommended limits for HD video (latency ≤150ms, jitter ≤40ms,
// loss ≤2%) costs nothing, so a link that carries a Zoom call without stutter reads 100%.
// Past the limit, each penalty follows a Hill curve on the excess e, max × eᵏ / (eᵏ + halfᵏ):
// half of `max` at `half` past the limit, saturating at `max`.
//
// - Loss only counts targets that answered at least once in the window, so a host that blocks
//   ICMP on this network is not mistaken for loss. With no such target (ICMP blocked, HTTP
//   fallback), a cycle that published nothing counts as lost.
// - Jitter is the mean absolute change between consecutive RTTs (RFC 3550 style): 15-100-15-100
//   scores badly, a slow drift does not. The largest ~10% of changes are trimmed so a single
//   wakeup spike, which produces two large changes, does not read as instability.
// - Latency is the window median. Latency caps at a 70% penalty: a stable, lossless satellite
//   link is slow, not broken.
// - Scores are computed every probe cycle over the last minute, then averaged over 10 seconds
//   for display so the menu bar does not flicker between neighbouring values.

import Foundation

struct HealthSample {
    /// Seconds since 1970.
    var at: TimeInterval
    var ms: Double?
    var source: LatencySource?
    /// Per-target verdicts in `Latency.icmpTargets` order.
    var targets: [Latency.EchoVerdict]
}

struct HealthReport: Equatable {
    /// 0–100.
    var score: Int
    /// 0–1.
    var loss: Double
    var jitterMs: Double?
    var latencyMs: Double?
}

struct HealthCurve {
    /// Values up to here cost nothing.
    var free: Double = 0
    /// Excess over `free` that costs half of `max`.
    let half: Double
    let steepness: Double
    let max: Double
    /// Where the penalty reaches `max` exactly; the curve is rescaled to hit it. Infinity = asymptotic.
    var full: Double = .infinity

    func penalty(_ x: Double) -> Double {
        guard x > free else { return 0 }
        guard x < full, x.isFinite else { return max }
        return max * hill(x - free) / (full.isFinite ? hill(full - free) : 1)
    }

    private func hill(_ x: Double) -> Double {
        let xk = pow(x, steepness)
        return xk / (xk + pow(half, steepness))
    }
}

enum Health {

    // MARK: - Tuning

    /// 20 probe cycles at the 3s probe interval.
    static let window: TimeInterval = 60
    /// Cycles needed before a score is shown; fewer cannot tell jitter from a single spike.
    static let minCycles = 3
    /// ≤2% free, 5% ≈ 32% penalty, 10% ≈ 67%, 100% = 100%.
    static let lossCurve = HealthCurve(free: 0.02, half: 0.05, steepness: 1.5, max: 1, full: 1)
    /// ≤40ms free, 60ms ≈ 31% penalty, 85ms ≈ 61%.
    static let jitterCurve = HealthCurve(free: 40, half: 25, steepness: 2, max: 0.8)
    /// ≤150ms free, 300ms ≈ 11% penalty, 600ms ≈ 44%, 1000ms ≈ 60%.
    static let latencyCurve = HealthCurve(free: 150, half: 350, steepness: 2, max: 0.7)
    /// The menu bar shows the mean score over this period and changes at most this often.
    static let displayInterval: TimeInterval = 10
    static let jitterTrim = 0.1

    // MARK: - Scoring

    /// Nil until the window holds `minCycles` cycles.
    static func evaluate(_ samples: [HealthSample]) -> HealthReport? {
        guard samples.count >= minCycles else { return nil }
        let loss = lossRate(samples)
        let jitter = jitterMs(samples)
        let latency = latencyMs(samples)
        let keep = (1 - lossCurve.penalty(loss))
            * (1 - jitterCurve.penalty(jitter ?? 0))
            * (1 - latencyCurve.penalty(latency ?? 0))
        let score = Int((100 * keep).rounded())
        return HealthReport(score: min(100, max(0, score)), loss: loss, jitterMs: jitter, latencyMs: latency)
    }

    static func lossRate(_ samples: [HealthSample]) -> Double {
        let slots = samples.map(\.targets.count).max() ?? 0
        var replied = 0, lost = 0
        for slot in 0..<slots {
            let verdicts = samples.compactMap { $0.targets.indices.contains(slot) ? $0.targets[slot] : nil }
            guard verdicts.contains(where: { if case .wan = $0 { return true } else { return false } }) else { continue }
            for v in verdicts {
                switch v {
                case .wan: replied += 1
                case .noReply: lost += 1
                case .onPath: break
                }
            }
        }
        if replied > 0 { return Double(lost) / Double(replied + lost) }
        return Double(samples.filter { $0.ms == nil }.count) / Double(samples.count)
    }

    /// Mean absolute change between consecutive same-source RTTs, top ~10% trimmed.
    static func jitterMs(_ samples: [HealthSample]) -> Double? {
        let rtts = samples.compactMap { s in s.ms.map { (ms: $0, source: s.source) } }
        guard rtts.count >= 2 else { return nil }
        var deltas: [Double] = []
        for (a, b) in zip(rtts, rtts.dropFirst()) where a.source == b.source {
            deltas.append(abs(b.ms - a.ms))
        }
        guard !deltas.isEmpty else { return nil }
        deltas.sort()
        let kept = deltas.dropLast(Int((Double(deltas.count) * jitterTrim).rounded()))
        return kept.reduce(0, +) / Double(kept.count)
    }

    /// Median RTT from the most recent source, matching what the menu bar shows.
    static func latencyMs(_ samples: [HealthSample]) -> Double? {
        guard let latest = samples.last(where: { $0.ms != nil }) else { return nil }
        return median(samples.filter { $0.source == latest.source }.compactMap(\.ms))
    }
}

/// Rolling window of probe cycles for one network.
struct HealthTracker {
    private(set) var samples: [HealthSample] = []

    /// Wall clock rather than uptime, which stops while the Mac sleeps.
    static func now() -> TimeInterval { Date().timeIntervalSince1970 }

    mutating func record(_ probe: WanProbe, at: TimeInterval = HealthTracker.now()) {
        samples.append(HealthSample(at: at, ms: probe.ms.flatMap { finiteNonNeg($0) },
                                    source: probe.source, targets: probe.verdicts))
        prune(now: at)
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    /// Cycles older than `Health.window` are ignored, so a long sleep does not leave stale history.
    func report(now: TimeInterval = HealthTracker.now()) -> HealthReport? {
        Health.evaluate(samples.filter { now - $0.at <= Health.window })
    }

    private mutating func prune(now: TimeInterval) {
        samples.removeAll { now - $0.at > Health.window }
    }
}

/// What the menu bar shows: the mean of the reports gathered since the last publish, republished
/// at most once per `Health.displayInterval`. The first report is shown as soon as it exists.
struct HealthDisplay {
    private(set) var shown: HealthReport?
    private var pending: [HealthReport] = []
    private var publishedAt: TimeInterval?

    mutating func add(_ report: HealthReport?) {
        if let report { pending.append(report) }
    }

    /// True when `shown` changed.
    mutating func publish(now: TimeInterval = HealthTracker.now()) -> Bool {
        guard !pending.isEmpty else { return false }
        if let at = publishedAt, now - at < Health.displayInterval { return false }
        let next = Self.mean(pending)
        pending.removeAll(keepingCapacity: true)
        publishedAt = now
        defer { shown = next }
        return next != shown
    }

    mutating func reset() {
        shown = nil
        pending.removeAll(keepingCapacity: true)
        publishedAt = nil
    }

    static func mean(_ reports: [HealthReport]) -> HealthReport {
        func avg(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
        let score = avg(reports.map { Double($0.score) }) ?? 0
        return HealthReport(score: Int(score.rounded()), loss: avg(reports.map(\.loss)) ?? 0,
                            jitterMs: avg(reports.compactMap(\.jitterMs)),
                            latencyMs: avg(reports.compactMap(\.latencyMs)))
    }
}
