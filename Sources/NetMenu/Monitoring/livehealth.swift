import Foundation

/// Partial rounds are replaced as replies arrive, never counted as extra probe cycles.
/// Website evidence has its own history so a single failed check cannot become two failures
/// merely because more ping replies arrived.
struct LiveHealthTracker {
    let config: HealthConfig
    let monitoring: MonitoringConfig
    init(config: HealthConfig = Configuration.health, monitoring: MonitoringConfig = Configuration.monitoring) {
        self.config = config; self.monitoring = monitoring
    }
    private(set) var wanFamily = IPVersion.ipv4
    private var rounds: [TimeInterval: HealthSample] = [:]
    private var fallbackSamples: [HealthSample] = []
    private var web: [(at: TimeInterval, reachable: Bool)] = []
    private var ipChecks: [(at: TimeInterval, ipv4: InternetStatus, ipv6: InternetStatus)] = []
    private var portalAt: TimeInterval?
    private var settleUntil: TimeInterval?

    mutating func reset() { self = Self(config: config, monitoring: monitoring) }
    /// Website evidence survives a transport switch; RTT, jitter and loss must not cross families.
    mutating func selectWANFamily(_ family: IPVersion) {
        guard family != wanFamily else { return }
        wanFamily = family
        rounds.removeAll(); fallbackSamples.removeAll()
    }
    mutating func settle(at now: TimeInterval = HealthTracker.now()) { settleUntil = now + config.settleLimit }
    private mutating func accept(success: Bool, at now: TimeInterval) -> Bool {
        if let until = settleUntil {
            guard success || now >= until else { return false }
            settleUntil = nil
        }
        rounds = rounds.filter { now - $0.key <= config.window }
        fallbackSamples.removeAll { now - $0.at > config.window }
        web.removeAll { now - $0.at > config.window }
        return true
    }

    @discardableResult
    mutating func recordTarget(slot: Int, verdict: Latency.EchoVerdict, started: TimeInterval,
                               at now: TimeInterval = HealthTracker.now()) -> Bool {
        guard verdict != .unmeasured else { return false }
        let success: Bool
        if case .wan = verdict { success = true } else { success = false }
        guard accept(success: success, at: now) else { return false }
        var sample = rounds[started] ?? HealthSample(at: started, ms: nil, source: nil,
            targets: Array(repeating: .unmeasured, count: Latency.icmpTargets(for: wanFamily).count), internet: .unknown)
        sample.targets[slot] = verdict
        let replies = sample.targets.compactMap { v -> Double? in if case .wan(let ms) = v { return ms }; return nil }
        sample.ms = replies.min(); sample.source = sample.ms == nil ? nil : .icmp
        rounds[started] = sample
        return true
    }

    mutating func recordFallback(_ ms: Double?, at now: TimeInterval = HealthTracker.now()) {
        guard accept(success: ms != nil, at: now) else { return }
        fallbackSamples.append(HealthSample(at: now, ms: ms, source: .http, targets: [], internet: .unknown))
    }

    mutating func recordWeb(_ checks: [String: Bool], at now: TimeInterval = HealthTracker.now()) {
        guard !checks.isEmpty else { return }
        let reachable = checks.values.contains(true)
        guard accept(success: reachable, at: now) else { return }
        web.append((now, reachable))
    }

    mutating func recordIPWeb(_ checks: IPWebsiteChecks, at now: TimeInterval = HealthTracker.now()) {
        let ipv4 = checks.status(for: .ipv4), ipv6 = checks.status(for: .ipv6)
        guard accept(success: ipv4 == .reachable || ipv6 == .reachable, at: now) else { return }
        ipChecks.removeAll { now - $0.at > monitoring.websiteFreshFor }
        ipChecks.append((now, ipv4, ipv6))
        recordWeb(checks.combined, at: now)
    }

    mutating func recordPortal(_ captive: Bool, at now: TimeInterval = HealthTracker.now()) {
        portalAt = captive ? now : nil
    }

    func hasFreshWebCheck(now: TimeInterval = HealthTracker.now()) -> Bool {
        web.last.map { now - $0.at <= monitoring.websiteFreshFor } ?? false
    }

    func transportReport(now: TimeInterval = HealthTracker.now()) -> HealthReport? {
        let samples = rounds.values.filter { now - $0.at <= config.window }.sorted { $0.at < $1.at }
        let http = fallbackSamples.filter { now - $0.at <= config.window }
        let lastWAN = samples.last(where: { $0.ms != nil })?.at
        let lastHTTPS = http.last(where: { $0.ms != nil })?.at
        // ICMP filtering must not look like loss when independent HTTPS probes work,
        // including when a previously pingable network starts filtering ICMP.
        let useHTTPS = lastWAN == nil || (lastHTTPS.map { $0 > lastWAN! } == true && now - lastWAN! > monitoring.wanFreshFor)
        return Health.evaluate(useHTTPS && !http.isEmpty ? http : samples, now: now, config: config)
    }

    func report(now: TimeInterval = HealthTracker.now()) -> HealthReport? {
        var result = transportReport(now: now)
        let samples = Array(rounds.values)
        let http = fallbackSamples
        let checks = web.filter { now - $0.at <= monitoring.websiteFreshFor }
        if let last = checks.last, !last.reachable {
            let portal = portalAt.map { now - $0 <= monitoring.websiteFreshFor } ?? false
            let noWAN = !samples.contains { now - $0.at <= monitoring.wanFreshFor && $0.ms != nil }
            let fallbackFailed = http.last.map { now - $0.at <= monitoring.fallbackFailureFreshFor && $0.ms == nil } ?? false
            let confirmed = portal || (noWAN && fallbackFailed) || checks.dropLast().last?.reachable == false
            if confirmed {
                if result == nil { result = HealthReport(score: 0, loss: 0, jitterMs: nil, latencyMs: nil) }
                result?.score = 0; result?.internetReachable = false
            } else { result?.websitesFailing = true }
        }
        let freshIP = ipChecks.filter { now - $0.at <= monitoring.websiteFreshFor }
        if let last = freshIP.last {
            let ipv4Unavailable = last.ipv4 == .unreachable && freshIP.dropLast().last?.ipv4 == .unreachable
            if ipv4Unavailable && result == nil {
                // Successful IPv6 websites establish partial access before RTT calibration.
                result = HealthReport(score: last.ipv6 == .reachable ? 100 : 0, loss: 0, jitterMs: nil, latencyMs: nil)
            }
            result?.ipv4Unavailable = ipv4Unavailable
            result?.ipv6Reachable = last.ipv6 == .reachable
            if ipv4Unavailable, let score = result?.score {
                // Keep working IPv6 visibly distinct from a complete outage, even if the
                // transport score rounds to zero while IPv4 pings are failing.
                result?.score = last.ipv6 == .reachable
                    ? max(1, Int((Double(score) / config.ipv6OnlyScoreDivisor).rounded())) : 0
            }
        }
        return result
    }

    func latencyReadings(now: TimeInterval = HealthTracker.now()) -> [Double] {
        rounds.values.filter { now - $0.at <= monitoring.latencyStaleAfter }.sorted { $0.at < $1.at }
            .compactMap(\.ms).suffix(monitoring.displayLatencyReadings).map { $0 }
    }
}

/// Short-lived evidence is independent of calibration and the smoothed quality score.
struct RecentTrouble {
    let config: MonitoringConfig
    let health: HealthConfig
    init(config: MonitoringConfig = Configuration.monitoring, health: HealthConfig = Configuration.health) {
        self.config = config; self.health = health
    }
    private var events: [String: TimeInterval] = [:]
    private var previous: [String: Double] = [:]
    mutating func record(_ verdict: Latency.EchoVerdict, target: String, label: String,
                         at now: TimeInterval = HealthTracker.now()) {
        switch verdict {
        case .wan(let ms):
            if Health.latencyPenalty(ms, config: health) > config.recentTroublePenalty { events["\(label) latency"] = now }
            if let old = previous[target], Health.jitterPenalty(abs(ms - old), latencyMs: max(ms, old), config: health) > config.recentTroublePenalty {
                events["\(label) jitter"] = now
            }
            previous[target] = ms
        case .noReply:
            // A destination that never answered may simply block probing.
            if previous[target] != nil { events["\(label) loss"] = now }
        case .onPath, .unmeasured: break
        }
        events = events.filter { now - $0.value < config.recentTroubleDuration }
    }
    mutating func websitesFailed(at now: TimeInterval = HealthTracker.now()) { events["web access"] = now }
    func labels(now: TimeInterval = HealthTracker.now()) -> [String] {
        events.filter { now - $0.value < config.recentTroubleDuration }.keys.sorted()
    }
}

/// Count completed connectivity recoveries, not startup, wakes, or metadata-only path updates.
struct ReconnectHistory {
    let config: MonitoringConfig
    init(config: MonitoringConfig = Configuration.monitoring) { self.config = config }
    private var wasConnected: Bool?
    private var disconnected = false
    private var recoveries: [TimeInterval] = []
    mutating func observe(connected: Bool, at now: TimeInterval = HealthTracker.now()) {
        if let before = wasConnected {
            if before && !connected { disconnected = true }
            if !before && connected && disconnected { recoveries.append(now); disconnected = false }
        }
        wasConnected = connected
        recoveries.removeAll { now - $0 >= config.reconnectWindow }
    }
    mutating func wake() { wasConnected = nil; disconnected = false }
    func count(now: TimeInterval = HealthTracker.now()) -> Int { recoveries.filter { now - $0 < config.reconnectWindow }.count }
}
