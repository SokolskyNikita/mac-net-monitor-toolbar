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
    mutating func expedite() { nextStart = lastStart.map { $0 + probeInterval } ?? 0 }
    mutating func resetSchedule() { nextStart = 0; lastStart = nil }
}

/// Main-thread scheduler; blocking transports run on workers. Every completion carries its epoch.
final class LiveProbes {
    enum Event {
        case wan(slot: Int, started: TimeInterval, outcome: Latency.PingOutcome, gatewayMs: Double?)
        case router(LocalProbeResult)
        case websites([String: Bool])
        case portal(Latency.Captive)
        case fallback(Double?)
    }
    struct Transport {
        var ping: (String, Int) -> Latency.PingOutcome = { Latency.ping($0, timeoutMs: $1) }
        var website: (Latency.InternetSite) -> Latency.InternetCheck = Latency.checkInternet
        var portal: () -> Latency.Captive = Latency.detectPortal
        var fallback: () -> Double? = Latency.httpProbe
    }
    private let transport: Transport
    init(transport: Transport = Transport()) { self.transport = transport }
    var receive: ((Int, Event) -> Void)?
    private var epoch: Int?
    private var epochStarted: TimeInterval = 0
    private var wan = Array(repeating: ProbeLane(), count: Latency.icmpTargets.count)
    private var router = ProbeLane(), websites = ProbeLane(), portal = ProbeLane(), fallback = ProbeLane()
    private let localSession = LocalProbeSession()
    private var gateway: (ms: Double, at: TimeInterval)?
    private var lastWAN: TimeInterval?
    private var lastPortal = Latency.Captive.unknown
    private var webHealthy = false
    private var troubleUntil: TimeInterval = 0

    func poll(identity: Identity, epoch: Int, paused: Bool, now: TimeInterval = HealthTracker.now()) {
        if self.epoch != epoch {
            self.epoch = epoch; epochStarted = now
            for i in wan.indices { wan[i].resetSchedule() }
            router.resetSchedule(); websites.resetSchedule(); portal.resetSchedule(); fallback.resetSchedule()
            gateway = nil; lastWAN = nil; lastPortal = .unknown; webHealthy = false; troubleUntil = 0
        }
        guard !paused else { return }
        if let target = identity.localRouter, router.start(at: now, interval: probeInterval) {
            work({ self.localSession.measure(target, epoch: epoch) }) { result in
                self.router.finish()
                guard self.epoch == epoch else { return }
                if result.method == .icmp, case .reply(let r) = result.outcome {
                    self.gateway = (r.ms, HealthTracker.now())
                } else { self.gateway = nil }
                self.receive?(epoch, .router(result))
            }
        }
        // All launches in this tick belong to one scoring round. Missing/busy slots stay unmeasured.
        for slot in wan.indices where wan[slot].start(at: now, interval: probeInterval) {
            let gw = gateway.flatMap { now - $0.at <= 10 ? $0.ms : nil }
            work({ self.transport.ping(Latency.icmpTargets[slot], Latency.icmpTimeoutMs) }) { result in
                self.wan[slot].finish()
                guard self.epoch == epoch else { return }
                let currentGateway = self.gateway.flatMap { HealthTracker.now() - $0.at <= 10 ? $0.ms : nil } ?? gw
                let verdict = Self.verdict(result, gatewayMs: currentGateway)
                if case .wan = verdict { self.lastWAN = HealthTracker.now() }
                else {
                    self.troubleUntil = HealthTracker.now() + 15
                    self.websites.expedite(); self.portal.expedite()
                }
                self.receive?(epoch, .wan(slot: slot, started: now, outcome: result, gatewayMs: currentGateway))
            }
        }
        let webInterval: TimeInterval = webHealthy && now >= troubleUntil ? 15 : probeInterval
        if websites.start(at: now, interval: webInterval) {
            work({
                let group = DispatchGroup(), results = LiveProbeResults()
                for site in Latency.InternetSite.allCases {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let check = self.transport.website(site)
                        DiagLog.shared.info("probe", "website \(site.rawValue) \(check.summary) epoch=\(epoch)")
                        switch check.outcome {
                        case .ok: results.set(site.rawValue, true)
                        case .failed: results.set(site.rawValue, false)
                        case .unmeasured: break
                        }
                        group.leave()
                    }
                }
                group.wait()
                return results.value
            }) { checks in
                self.websites.finish()
                guard self.epoch == epoch else { return }
                self.webHealthy = checks.values.contains(true)
                if !self.webHealthy { self.websites.expedite() }
                self.receive?(epoch, .websites(checks))
            }
        }
        if portal.start(at: now, interval: webInterval) {
            work({ self.transport.portal() }) { result in
                self.portal.finish()
                guard self.epoch == epoch else { return }
                self.lastPortal = result
                if result == .portal {
                    self.troubleUntil = HealthTracker.now() + 15; self.websites.expedite()
                }
                self.receive?(epoch, .portal(result))
            }
        }
        // Give the first ICMP round its deadline before starting a fallback. Thereafter the
        // fallback has its own clock and never delays router, WAN, or website measurements.
        let needsFallback = lastWAN.map { now - $0 > 10 } ?? (now - epochStarted >= 8)
        if needsFallback, lastPortal != .portal, fallback.start(at: now, interval: probeInterval) {
            work({ self.transport.fallback() }) { ms in
                self.fallback.finish()
                guard self.epoch == epoch else { return }
                self.receive?(epoch, .fallback(ms))
            }
        }
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

private final class LiveProbeResults {
    private let lock = NSLock()
    private var stored: [String: Bool] = [:]
    func set(_ site: String, _ ok: Bool) { lock.lock(); defer { lock.unlock() }; stored[site] = ok }
    var value: [String: Bool] { lock.lock(); defer { lock.unlock() }; return stored }
}
