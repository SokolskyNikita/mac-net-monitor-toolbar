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
// - Measurements this Mac could not make (a helper failed to launch, a ping target did not
//   resolve, a probe was cut off) are excluded everywhere. A local fault never reads as loss.
// - Loss is per target: each host that answered at least once in the window gets its own loss
//   rate. The lossiest host is dropped (keeping a majority) only while it is both more than 10
//   points worse than the others pooled and statistically implausible under their rate
//   (binomial tail < 1%), so one host rate-limiting ICMP is not mistaken for a bad link, while
//   real loss, which hits every host alike, still counts in full even over a few cycles. With no such host (ICMP
//   blocked, HTTP fallback), a cycle that published nothing counts as lost.
// - Jitter is the mean absolute change between consecutive RTTs to the same host (RFC 3550, per
//   stream): 15-100-15-100 scores badly, a slow drift does not, and the fastest host changing
//   from one cycle to the next is not jitter. The largest ~10% of changes are trimmed so a single
//   wakeup spike, which produces two large changes, does not read as instability.
//   Above 200ms median RTT, divide jitter by RTT/200 before applying the curve. This scales
//   both the free allowance and penalty ramp: up to max(40ms, 20% of RTT) costs nothing.
//   This is a relative-stability heuristic, not a real-time application's jitter guarantee.
// - Latency is the window median. Latency caps at a 70% penalty: a stable, lossless satellite
//   link is slow, not broken.
// - Scores are computed every probe cycle over the last minute, then averaged over 10 seconds
//   for display so the menu bar does not flicker between neighbouring values.
// - Outage: when every ordinary HTTPS check fails, health is 0% once the failure is confirmed:
//   immediately if nothing else got through that cycle or a login wall is up, otherwise on the
//   second failing cycle in a row, so one dropped request on a working link cannot zero the
//   score. Neither calibration nor display smoothing can hide a confirmed outage.
// - After wake or a network change, cycles are ignored until something answers (at most
//   `settleLimit`), so the seconds Wi-Fi takes to rejoin do not read as loss for a minute.
// - Time is monotonic and includes sleep, so wall-clock changes cannot keep stale cycles.

import Foundation

struct HealthSample {
    /// Monotonic seconds (`HealthTracker.now()`).
    var at: TimeInterval
    var ms: Double?
    var source: LatencySource?
    /// Per-target verdicts in `Latency.icmpTargets` order.
    var targets: [Latency.EchoVerdict]
    var internet: InternetStatus
    /// This cycle alone confirms failed website checks (see `WanProbe.corroboratesOutage`).
    var corroborated: Bool = false
}

extension HealthSample {
    init(at: TimeInterval, ms: Double?, source: LatencySource?, targets: [Latency.EchoVerdict],
         internetReachable: Bool, corroborated: Bool = false) {
        self.init(at: at, ms: ms, source: source, targets: targets,
                  internet: internetReachable ? .reachable : .unreachable, corroborated: corroborated)
    }
}

struct HealthReport: Equatable {
    /// 0–100.
    var score: Int
    /// 0–1.
    var loss: Double
    var jitterMs: Double?
    var latencyMs: Double?
    /// False only during a confirmed outage.
    var internetReachable: Bool = true
    /// The latest website checks failed but the outage is not confirmed yet.
    var websitesFailing: Bool = false
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
    /// A host this much lossier than the others pooled, and at least this unlikely under their
    /// loss rate, is treated as filtering ICMP.
    static let lossOutlierMargin = 0.10
    static let lossOutlierPValue = 0.01
    /// Normalized jitter: ≤40ms free, 60ms ≈ 31% penalty, 85ms ≈ 61%.
    static let jitterCurve = HealthCurve(free: 40, half: 25, steepness: 2, max: 0.8)
    /// Preserve the absolute jitter curve on fast links; scale it with RTT above this point.
    static let jitterReferenceLatency: Double = 200
    /// ≤150ms free, 300ms ≈ 11% penalty, 600ms ≈ 44%, 1000ms ≈ 60%.
    static let latencyCurve = HealthCurve(free: 150, half: 350, steepness: 2, max: 0.7)
    /// The menu bar shows the mean score over this period and changes at most this often.
    static let displayInterval: TimeInterval = 10
    static let jitterTrim = 0.1
    /// Longest wait after wake or a network change before failures count again.
    static let settleLimit: TimeInterval = 30

    // MARK: - Scoring

    /// Nil until calibrated, except a confirmed outage immediately reports zero.
    static func evaluate(_ samples: [HealthSample]) -> HealthReport? {
        guard !samples.isEmpty else { return nil }
        let outage = confirmedOutage(samples)
        guard samples.count >= minCycles || outage else { return nil }
        let loss = lossRate(samples)
        let jitter = jitterMs(samples)
        let latency = latencyMs(samples)
        let keep = (1 - lossCurve.penalty(loss))
            * (1 - jitterPenalty(jitter ?? 0, latencyMs: latency))
            * (1 - latencyCurve.penalty(latency ?? 0))
        let raw = 100 * keep
        let score = outage || !raw.isFinite ? 0 : Int(raw.rounded())
        let failing = samples.last(where: { $0.internet != .unknown })?.internet == .unreachable
        return HealthReport(score: min(100, max(0, score)), loss: loss, jitterMs: jitter,
                            latencyMs: latency, internetReachable: !outage,
                            websitesFailing: failing && !outage)
    }

    /// The latest judged website check failed, and either that cycle corroborates it or the
    /// judged cycle before it failed too. Cycles whose checks could not run are skipped.
    static func confirmedOutage(_ samples: [HealthSample]) -> Bool {
        let judged = samples.filter { $0.internet != .unknown }
        guard let last = judged.last, last.internet == .unreachable else { return false }
        return last.corroborated || judged.dropLast().last?.internet == .unreachable
    }

    /// A 100ms variation is small on a 650ms link but disruptive on a 50ms link.
    /// Keep reporting raw jitter in milliseconds; only its scoring input is normalized.
    static func jitterPenalty(_ jitter: Double, latencyMs: Double?) -> Double {
        let baseline = latencyMs.flatMap { finiteNonNeg($0) } ?? 0
        let scale = max(1, baseline / jitterReferenceLatency)
        return jitterCurve.penalty(jitter / scale)
    }

    static func lossRate(_ samples: [HealthSample]) -> Double {
        guard !samples.isEmpty else { return 0 }
        struct Tally { var lost = 0, sent = 0; var rate: Double { Double(lost) / Double(sent) } }
        let slots = samples.map(\.targets.count).max() ?? 0
        var tallies: [Tally] = []
        for slot in 0..<slots {
            var t = Tally(), answered = false
            for s in samples where s.targets.indices.contains(slot) {
                switch s.targets[slot] {
                case .wan: t.sent += 1; answered = true
                case .noReply: t.sent += 1; t.lost += 1
                case .onPath, .unmeasured: break
                }
            }
            if answered { tallies.append(t) }
        }
        func pooled(_ ts: ArraySlice<Tally>) -> Double {
            let sent = ts.reduce(0) { $0 + $1.sent }
            return sent > 0 ? Double(ts.reduce(0) { $0 + $1.lost }) / Double(sent) : 0
        }
        if !tallies.isEmpty {
            var kept = tallies.sorted { $0.rate < $1.rate }[...]
            let minKeep = tallies.count / 2 + 1
            while kept.count > minKeep, let worst = kept.last {
                let rest = kept.dropLast()
                let restLost = rest.reduce(0) { $0 + $1.lost }, restSent = rest.reduce(0) { $0 + $1.sent }
                // Laplace-smoothed, so "the others lost nothing" does not make any loss impossible.
                let p = Double(restLost + 1) / Double(restSent + 2)
                guard worst.rate - pooled(rest) > lossOutlierMargin,
                      binomialUpperTail(k: worst.lost, n: worst.sent, p: p) < lossOutlierPValue else { break }
                kept = rest
            }
            return pooled(kept)
        }
        return Double(samples.filter { $0.ms == nil }.count) / Double(samples.count)
    }

    /// P(X ≥ k) for X ~ Binomial(n, p).
    static func binomialUpperTail(k: Int, n: Int, p: Double) -> Double {
        guard k > 0 else { return 1 }
        guard k <= n, p > 0 else { return 0 }
        guard p < 1 else { return 1 }
        var total = 0.0
        for i in k...n {
            let logC = lgamma(Double(n + 1)) - lgamma(Double(i + 1)) - lgamma(Double(n - i + 1))
            total += exp(logC + Double(i) * log(p) + Double(n - i) * log1p(-p))
        }
        return min(1, total)
    }

    /// Mean absolute change between consecutive RTTs to the same host, top ~10% trimmed.
    /// Without ICMP replies, falls back to consecutive same-source published RTTs.
    static func jitterMs(_ samples: [HealthSample]) -> Double? {
        var deltas: [Double] = []
        if samples.last(where: { $0.ms != nil })?.source == .icmp {
            let slots = samples.map(\.targets.count).max() ?? 0
            for slot in 0..<slots {
                var previous: Double?
                for s in samples where s.targets.indices.contains(slot) {
                    guard case .wan(let ms) = s.targets[slot], ms.isFinite else { continue }
                    if let previous { deltas.append(abs(ms - previous)) }
                    previous = ms
                }
            }
        }
        if deltas.isEmpty {
            let rtts = samples.compactMap { s in s.ms.map { (ms: $0, source: s.source) } }
            for (a, b) in zip(rtts, rtts.dropFirst()) where a.source == b.source {
                deltas.append(abs(b.ms - a.ms))
            }
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
    private(set) var settleUntil: TimeInterval?

    enum Recorded: String {
        case recorded
        /// Nothing in the cycle could be measured.
        case unmeasured
        /// Waiting for the network to come up after wake or a network change.
        case settling
    }

    /// Monotonic and includes sleep: wall-clock changes cannot keep stale cycles in the window.
    static func now() -> TimeInterval { BandwidthClock.now() }

    @discardableResult
    mutating func record(_ probe: WanProbe, at: TimeInterval = HealthTracker.now()) -> Recorded {
        guard probe.measured else { return .unmeasured }
        if let until = settleUntil {
            guard probe.anySuccess || at >= until else { return .settling }
            settleUntil = nil
        }
        samples.append(HealthSample(at: at, ms: probe.ms.flatMap { finiteNonNeg($0) },
                                    source: probe.source, targets: probe.verdicts,
                                    internet: probe.internet, corroborated: probe.corroboratesOutage))
        prune(now: at)
        return .recorded
    }

    /// Ignore failing cycles until something answers or `Health.settleLimit` passes.
    mutating func settle(at now: TimeInterval = HealthTracker.now()) {
        settleUntil = now + Health.settleLimit
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    /// Cycles older than `Health.window` are ignored, so a long sleep does not leave stale history.
    func report(now: TimeInterval = HealthTracker.now()) -> HealthReport? {
        Health.evaluate(samples.filter { Self.isCurrent($0, now: now) })
    }

    private static func isCurrent(_ s: HealthSample, now: TimeInterval) -> Bool {
        now - s.at <= Health.window && s.at <= now + 1
    }

    private mutating func prune(now: TimeInterval) {
        samples.removeAll { !Self.isCurrent($0, now: now) }
    }
}

/// What the menu bar shows: the mean of the reports gathered since the last publish, republished
/// at most once per `Health.displayInterval`. The first report is shown as soon as it exists.
struct HealthDisplay {
    private(set) var shown: HealthReport?
    private var pending: [HealthReport] = []
    private var publishedAt: TimeInterval?

    mutating func add(_ report: HealthReport?) {
        guard let report else { return }
        // Do not average a confirmed outage with an earlier healthy score (or vice versa).
        if !report.internetReachable || pending.last?.internetReachable != report.internetReachable {
            pending.removeAll(keepingCapacity: true)
        }
        pending.append(report)
    }

    /// True when `shown` changed.
    mutating func publish(now: TimeInterval = HealthTracker.now()) -> Bool {
        guard !pending.isEmpty else { return false }
        let accessChanged = pending.last?.internetReachable != shown?.internetReachable
        if !accessChanged, pending.last?.internetReachable != false,
           let at = publishedAt, now - at < Health.displayInterval { return false }
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
                            latencyMs: avg(reports.compactMap(\.latencyMs)),
                            internetReachable: reports.last?.internetReachable ?? false,
                            websitesFailing: reports.last?.websitesFailing ?? false)
    }
}
