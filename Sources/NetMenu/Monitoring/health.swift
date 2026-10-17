// Connection health estimates interactive usability from loss and a shared delay budget.
// D = 40 + RTT/2 + jitter (milliseconds)
// health = round(100 * 2^(-max(0, lossPercent - 1)/4 - (max(0, D - 150)/200)^2))
//
// The structure reflects the receiver's buffering tradeoff: jitter adds delay instead of
// receiving an independent penalty. These constants are product calibration, not an ITU
// or Zoom quality prediction. RTT/2 assumes symmetric paths; 40ms + jitter approximates
// processing and buffering, which our probes cannot measure directly.
//
// Loss and jitter use weighted means; RTT uses a weighted median. All use a 15-second
// exponential half-life within a 60-second window. Jitter compares consecutive replies
// to the same target, without trimming spikes or scaling by baseline latency.
// Unmeasured probes and statistically abnormal targets remain excluded from loss.
// Display scores are averaged over 10 seconds. Confirmed website outages immediately
// force zero, bypassing calibration and smoothing. Wake/network settling is unchanged.

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
    /// Two complete IPv4 website rounds failed; IPv6 success cannot mask this critical failure.
    var ipv4Unavailable: Bool = false
    var ipv6Reachable: Bool = false
    /// Sources contributing to the displayed RTT, including a smoothed source transition.
    var latencySources: Set<LatencySource> = []
}

enum Health {

    // Default model metadata; calculations accept a section override.
    static let window = Configuration.health.window
    static let minCycles = Configuration.health.minCycles
    static let model = Configuration.health.model
    static let recencyHalfLife = Configuration.health.recencyHalfLife
    static let processingAllowanceMs = Configuration.health.processingAllowanceMs
    static let freeDelayMs = Configuration.health.freeDelayMs
    static let delayHalfScaleMs = Configuration.health.delayHalfScaleMs
    static let freeLoss = Configuration.health.freeLoss
    static let lossHalfScale = Configuration.health.lossHalfScale
    static let lossOutlierMargin = Configuration.health.lossOutlierMargin
    static let lossOutlierPValue = Configuration.health.lossOutlierPValue
    static let displayInterval = Configuration.health.displayInterval
    static let settleLimit = Configuration.health.settleLimit

    // MARK: - Scoring

    /// Nil until calibrated, except a confirmed outage immediately reports zero.
    static func evaluate(_ samples: [HealthSample], now: TimeInterval? = nil, config: HealthConfig = Configuration.health) -> HealthReport? {
        let now = now ?? samples.map(\.at).max() ?? 0
        let samples = samples.filter { $0.at.isFinite && now - $0.at <= config.window && $0.at <= now + 1 }
        guard !samples.isEmpty else { return nil }
        let outage = confirmedOutage(samples)
        guard samples.count >= config.minCycles || outage else { return nil }
        let loss = lossRate(samples, now: now, config: config)
        let jitter = jitterMs(samples, now: now, config: config)
        let latency = latencyMs(samples, now: now, config: config)
        let raw = rawScore(loss: loss, jitterMs: jitter ?? 0, latencyMs: latency ?? 0, config: config)
        let score = outage || !raw.isFinite ? 0 : Int(raw.rounded())
        let failing = samples.last(where: { $0.internet != .unknown })?.internet == .unreachable
        return HealthReport(score: min(100, max(0, score)), loss: loss, jitterMs: jitter,
                            latencyMs: latency, internetReachable: !outage,
                            websitesFailing: failing && !outage,
                            latencySources: Set(samples.last(where: { $0.ms != nil })?.source.map { [$0] } ?? []))
    }

    /// The latest judged website check failed, and either that cycle corroborates it or the
    /// judged cycle before it failed too. Cycles whose checks could not run are skipped.
    static func confirmedOutage(_ samples: [HealthSample]) -> Bool {
        let judged = samples.filter { $0.internet != .unknown }
        guard let last = judged.last, last.internet == .unreachable else { return false }
        return last.corroborated || judged.dropLast().last?.internet == .unreachable
    }

    /// Fractional score before UI rounding; loss is 0...1, RTT and jitter are milliseconds.
    static func rawScore(loss: Double, jitterMs: Double, latencyMs: Double, config: HealthConfig = Configuration.health) -> Double {
        let lossCost = max(0, loss - config.freeLoss) / config.lossHalfScale
        return 100 * exp2(-lossCost - delayCost(latencyMs: latencyMs, jitterMs: jitterMs, config: config))
    }

    static func delayCost(latencyMs: Double, jitterMs: Double = 0, config: HealthConfig = Configuration.health) -> Double {
        let delay = config.processingAllowanceMs + latencyMs / 2 + jitterMs
        let excess = max(0, delay - config.freeDelayMs) / config.delayHalfScaleMs
        return excess * excess
    }

    /// Recent trouble uses the same model without the window or display smoothing.
    static func latencyPenalty(_ latencyMs: Double, config: HealthConfig = Configuration.health) -> Double {
        1 - exp2(-delayCost(latencyMs: latencyMs, config: config))
    }

    /// Incremental penalty from jitter, so a stable slow link does not also warn of jitter.
    static func jitterPenalty(_ jitter: Double, latencyMs: Double, config: HealthConfig = Configuration.health) -> Double {
        let extraCost = delayCost(latencyMs: latencyMs, jitterMs: jitter, config: config) - delayCost(latencyMs: latencyMs, config: config)
        return 1 - exp2(-extraCost)
    }

    /// Exponential decay; slightly future-dated samples are capped at weight one.
    static func recencyWeight(age: TimeInterval, config: HealthConfig = Configuration.health) -> Double {
        guard age.isFinite, age <= config.window else { return 0 }
        return exp2(-max(0, age) / config.recencyHalfLife)
    }

    static func lossRate(_ samples: [HealthSample], now: TimeInterval, config: HealthConfig = Configuration.health) -> Double {
        guard !samples.isEmpty else { return 0 }
        struct Tally {
            var lost = 0, sent = 0
            var lostWeight = 0.0, sentWeight = 0.0
            var rate: Double { Double(lost) / Double(sent) }
        }
        let slots = samples.map(\.targets.count).max() ?? 0
        var tallies: [Tally] = []
        for slot in 0..<slots {
            var t = Tally(), answered = false
            for s in samples where s.targets.indices.contains(slot) {
                let weight = recencyWeight(age: now - s.at, config: config)
                switch s.targets[slot] {
                case .wan: t.sent += 1; t.sentWeight += weight; answered = true
                case .noReply:
                    t.sent += 1; t.lost += 1; t.sentWeight += weight; t.lostWeight += weight
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
                guard worst.rate - pooled(rest) > config.lossOutlierMargin,
                      binomialUpperTail(k: worst.lost, n: worst.sent, p: p) < config.lossOutlierPValue else { break }
                kept = rest
            }
            let weight = kept.reduce(0) { $0 + $1.sentWeight }
            return weight > 0 ? kept.reduce(0) { $0 + $1.lostWeight } / weight : 0
        }
        let weight = samples.reduce(0) { $0 + recencyWeight(age: now - $1.at, config: config) }
        let lostWeight = samples.filter { $0.ms == nil }.reduce(0) { $0 + recencyWeight(age: now - $1.at, config: config) }
        return weight > 0 ? lostWeight / weight : 0
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

    /// Weighted mean absolute change between consecutive RTTs to the same host, including spikes.
    /// Without ICMP replies, falls back to consecutive same-source published RTTs.
    static func jitterMs(_ samples: [HealthSample], now: TimeInterval, config: HealthConfig = Configuration.health) -> Double? {
        var deltas: [(value: Double, weight: Double)] = []
        if samples.last(where: { $0.ms != nil })?.source == .icmp {
            let slots = samples.map(\.targets.count).max() ?? 0
            for slot in 0..<slots {
                var previous: Double?
                for s in samples where s.targets.indices.contains(slot) {
                    guard case .wan(let ms) = s.targets[slot], ms.isFinite else { continue }
                    if let previous { deltas.append((abs(ms - previous), recencyWeight(age: now - s.at, config: config))) }
                    previous = ms
                }
            }
        }
        if deltas.isEmpty {
            let rtts = samples.compactMap { s in s.ms.map { (ms: $0, source: s.source, at: s.at) } }
            for (a, b) in zip(rtts, rtts.dropFirst()) where a.source == b.source {
                deltas.append((abs(b.ms - a.ms), recencyWeight(age: now - b.at, config: config)))
            }
        }
        guard !deltas.isEmpty else { return nil }
        let weight = deltas.reduce(0) { $0 + $1.weight }
        return weight > 0 ? deltas.reduce(0) { $0 + $1.value * $1.weight } / weight : nil
    }

    /// Recency-weighted median RTT from the most recent source. The menu-bar RTT keeps its
    /// separate five-reading median; this value is the latency input to connection health.
    static func latencyMs(_ samples: [HealthSample], now: TimeInterval, config: HealthConfig = Configuration.health) -> Double? {
        guard let latest = samples.last(where: { $0.ms != nil }) else { return nil }
        let values = samples.filter { $0.source == latest.source }.compactMap { s -> (value: Double, weight: Double)? in
            guard let ms = s.ms else { return nil }
            return (ms, recencyWeight(age: now - s.at, config: config))
        }.filter { $0.weight > 0 }.sorted { $0.value < $1.value }
        let half = values.reduce(0) { $0 + $1.weight } / 2
        var cumulative = 0.0
        for (i, entry) in values.enumerated() {
            cumulative += entry.weight
            if abs(cumulative - half) < 1e-12, i + 1 < values.count {
                return (entry.value + values[i + 1].value) / 2
            }
            if cumulative > half { return entry.value }
        }
        return values.last?.value
    }
}

/// Rolling window of probe cycles for one network.
struct HealthTracker {
    let config: HealthConfig
    init(config: HealthConfig = Configuration.health) { self.config = config }
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
        settleUntil = now + config.settleLimit
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    /// Cycles older than `Health.window` are ignored, so a long sleep does not leave stale history.
    func report(now: TimeInterval = HealthTracker.now()) -> HealthReport? {
        Health.evaluate(samples, now: now, config: config)
    }

    private mutating func prune(now: TimeInterval) {
        samples.removeAll { !(now - $0.at <= config.window && $0.at <= now + 1) }
    }
}

/// What the menu bar shows: the mean of the reports gathered since the last publish, republished
/// at most once per `Health.displayInterval`. The first report is shown as soon as it exists.
struct HealthDisplay {
    let config: HealthConfig
    init(config: HealthConfig = Configuration.health) { self.config = config }
    private(set) var shown: HealthReport?
    private var pending: [HealthReport] = []
    private var publishedAt: TimeInterval?

    mutating func add(_ report: HealthReport?) {
        guard let report else { return }
        // Do not average a confirmed outage with an earlier healthy score (or vice versa).
        if !report.internetReachable || report.ipv4Unavailable
            || pending.last?.internetReachable != report.internetReachable
            || pending.last?.ipv4Unavailable != report.ipv4Unavailable {
            pending.removeAll(keepingCapacity: true)
        }
        pending.append(report)
    }

    /// True when `shown` changed.
    mutating func publish(now: TimeInterval = HealthTracker.now()) -> Bool {
        guard !pending.isEmpty else { return false }
        let accessChanged = pending.last?.internetReachable != shown?.internetReachable
            || pending.last?.ipv4Unavailable != shown?.ipv4Unavailable
            || (pending.last?.ipv4Unavailable == true && pending.last?.ipv6Reachable != shown?.ipv6Reachable)
        if !accessChanged, pending.last?.internetReachable != false, pending.last?.ipv4Unavailable != true,
           let at = publishedAt, now - at < config.displayInterval { return false }
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
                            websitesFailing: reports.last?.websitesFailing ?? false,
                            ipv4Unavailable: reports.last?.ipv4Unavailable ?? false,
                            ipv6Reachable: reports.last?.ipv6Reachable ?? false,
                            latencySources: reports.reduce(into: Set<LatencySource>()) { $0.formUnion($1.latencySources) })
    }
}
