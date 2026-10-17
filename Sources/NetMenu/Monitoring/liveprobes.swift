import Foundation

/// Each lane owns one outstanding request. Slow work never queues more copies of itself.
struct ProbeLane {
    private(set) var busy = false
    private(set) var nextStart: TimeInterval = 0
    private var lastStart: TimeInterval?
    mutating func start(at now: TimeInterval, interval: TimeInterval) -> Bool {
        guard !busy, now >= nextStart else { return false }
        busy = true; lastStart = now; nextStart = now + interval
        return true
    }
    mutating func finish() { busy = false }
    mutating func expedite(interval: TimeInterval = Configuration.monitoring.probeInterval) { nextStart = lastStart.map { $0 + interval } ?? 0 }
    mutating func resetSchedule() { nextStart = 0; lastStart = nil }
}

/// Main-thread scheduler; blocking transports run on workers. Every completion carries its epoch.
final class LiveProbes {
    enum Event {
        case wanFamily(IPVersion)
        case wan(family: IPVersion, slot: Int, started: TimeInterval, outcome: Latency.PingOutcome, gatewayMs: Double?)
        case router(LocalProbeResult)
        case websites(IPWebsiteChecks)
        case portal(Latency.Captive)
        case fallback(family: IPVersion, ms: Double?)
    }
    struct Transport {
        var ping: (String, Int) -> Latency.PingOutcome = { Latency.ping($0, timeoutMs: $1) }
        var website: (Latency.InternetSite, IPVersion) -> Latency.InternetCheck = { Latency.checkInternet($0, family: $1) }
        var portal: () -> Latency.Captive = Latency.detectPortal
        var fallback: (IPVersion) -> Double? = { Latency.httpProbe(family: $0) }
        /// A session per transport preserves protocol selection without coupling scheduling
        /// to real router sockets. Tests can replace this lane just like every WAN lane.
        var local: (LocalRouter, Int) -> LocalProbeResult? = {
            let session = LocalProbeSession()
            return { router, epoch in session.poll(router, epoch: epoch) }
        }()
    }
    private let transport: Transport
    private let config: MonitoringConfig
    init(transport: Transport = Transport(), config: MonitoringConfig = Configuration.monitoring) {
        self.transport = transport; self.config = config
    }
    var receive: ((Int, Event) -> Void)?
    private var epoch: Int?
    private var epochStarted: TimeInterval = 0
    private var wan: [String: ProbeLane] = [:]
    private var wanFamily = IPVersion.ipv4
    private var wanGeneration = 0
    private var router = ProbeLane(), websites = ProbeLane(), portal = ProbeLane()
    private var fallback: [IPVersion: ProbeLane] = [:]
    private var gateway: (ms: Double, at: TimeInterval, family: IPVersion)?
    private var lastWAN: TimeInterval?
    private var lastPortal = Latency.Captive.unknown
    private var webHealthy = false
    private var troubleUntil: TimeInterval = 0

    func poll(identity: Identity, epoch: Int, paused: Bool, now: TimeInterval = HealthTracker.now()) {
        if self.epoch != epoch {
            self.epoch = epoch; epochStarted = now
            for host in Array(wan.keys) { wan[host]?.resetSchedule() }
            selectWANFamily(.ipv4, epoch: epoch, now: now)
            router.resetSchedule(); websites.resetSchedule(); portal.resetSchedule()
            for family in IPVersion.allCases { fallback[family]?.resetSchedule() }
            gateway = nil; lastWAN = nil; lastPortal = .unknown; webHealthy = false; troubleUntil = 0
        }
        guard !paused else { return }
        if let target = identity.localRouter, router.start(at: now, interval: config.localConfirmationInterval) {
            work({ self.transport.local(target, epoch) }) { result in
                self.router.finish()
                guard self.epoch == epoch, let result else { return }
                if result.method == .icmp, case .reply(let r) = result.outcome {
                    self.gateway = (r.ms, HealthTracker.now(), target.address.contains(":") ? .ipv6 : .ipv4)
                } else { self.gateway = nil }
                self.receive?(epoch, .router(result))
            }
        }
        // Switching families gives IPv6 its own lanes; old IPv4 timeouts cannot hold it up.
        let family = wanFamily, generation = wanGeneration
        for (slot, host) in Latency.icmpTargets(for: family).enumerated()
            where wan[host, default: ProbeLane()].start(at: now, interval: config.probeInterval) {
            let gw = gateway.flatMap { $0.family == family && now - $0.at <= self.config.gatewayFreshFor ? $0.ms : nil }
            work({ self.transport.ping(host, self.config.icmpTimeoutMs) }) { result in
                self.wan[host]?.finish()
                guard self.epoch == epoch, self.wanGeneration == generation else { return }
                let currentGateway = self.gateway.flatMap {
                    $0.family == family && HealthTracker.now() - $0.at <= self.config.gatewayFreshFor ? $0.ms : nil
                } ?? gw
                let verdict = Self.verdict(result, gatewayMs: currentGateway)
                if case .wan = verdict { self.lastWAN = HealthTracker.now() }
                else {
                    self.troubleUntil = HealthTracker.now() + self.config.troubleProbeDuration
                    self.websites.expedite(interval: self.config.probeInterval); self.portal.expedite(interval: self.config.probeInterval)
                }
                self.receive?(epoch, .wan(family: family, slot: slot, started: now, outcome: result, gatewayMs: currentGateway))
            }
        }
        let webInterval: TimeInterval = webHealthy && now >= troubleUntil ? config.healthyWebsiteInterval : config.probeInterval
        if websites.start(at: now, interval: webInterval) {
            work({
                let group = DispatchGroup(), results = Locked(IPWebsiteChecks())
                for family in IPVersion.allCases {
                    for site in Latency.InternetSite.allCases {
                        group.enter()
                        DispatchQueue.global(qos: .utility).async {
                            let check = self.transport.website(site, family)
                            DiagLog.shared.info("probe", "website \(site.rawValue) \(family.rawValue) \(check.summary) epoch=\(epoch)")
                            results.mutate { $0.record(check, site: site, family: family) }
                            group.leave()
                        }
                    }
                }
                group.wait()
                return results.value
            }) { checks in
                self.websites.finish()
                guard self.epoch == epoch else { return }
                self.webHealthy = checks.status(for: .ipv4) == .reachable
                if self.webHealthy {
                    self.selectWANFamily(.ipv4, epoch: epoch, now: HealthTracker.now())
                } else if checks.status(for: .ipv4) == .unreachable && checks.status(for: .ipv6) == .reachable {
                    self.selectWANFamily(.ipv6, epoch: epoch, now: HealthTracker.now())
                }
                if !self.webHealthy { self.websites.expedite(interval: self.config.probeInterval) }
                self.receive?(epoch, .websites(checks))
            }
        }
        if portal.start(at: now, interval: webInterval) {
            work({ self.transport.portal() }) { result in
                self.portal.finish()
                guard self.epoch == epoch else { return }
                self.lastPortal = result
                if result == .portal {
                    self.troubleUntil = HealthTracker.now() + self.config.troubleProbeDuration; self.websites.expedite(interval: self.config.probeInterval)
                }
                self.receive?(epoch, .portal(result))
            }
        }
        // Give the first ICMP round its deadline before starting a fallback. Thereafter the
        // fallback has its own clock and never delays router, WAN, or website measurements.
        let needsFallback = lastWAN.map { now - $0 > config.wanFreshFor } ?? (now - epochStarted >= config.initialFallbackDelay)
        if needsFallback, (lastPortal != .portal || family == .ipv6), fallback[family, default: ProbeLane()].start(at: now, interval: config.probeInterval) {
            work({ self.transport.fallback(family) }) { ms in
                self.fallback[family]?.finish()
                guard self.epoch == epoch, self.wanGeneration == generation else { return }
                self.receive?(epoch, .fallback(family: family, ms: ms))
            }
        }
    }

    private func selectWANFamily(_ family: IPVersion, epoch: Int, now: TimeInterval) {
        guard wanFamily != family else { return }
        wanFamily = family; wanGeneration &+= 1
        lastWAN = nil; epochStarted = now
        for host in Latency.icmpTargets(for: family) { wan[host]?.resetSchedule() }
        fallback[family]?.resetSchedule()
        receive?(epoch, .wanFamily(family))
    }

    private func work<T>(_ operation: @escaping () -> T, completion: @escaping (T) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = autoreleasepool(invoking: operation)
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func verdict(_ outcome: Latency.PingOutcome, gatewayMs: Double?) -> Latency.EchoVerdict {
        switch outcome {
        case .reply(let r): return Latency.judge(r, gatewayMs: gatewayMs)
        case .lost: return .noReply
        case .unmeasured: return .unmeasured
        }
    }
}
