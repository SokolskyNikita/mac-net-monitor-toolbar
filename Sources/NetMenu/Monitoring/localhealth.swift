import Foundation

/// Router-only samples use the same loss, jitter and latency curves as WAN health.
/// No HTTPS verdict participates; a router that has never answered may simply filter our probes.
struct LocalHealthTracker {
    private var samples: [HealthSample] = []
    private var hasAnswered = false
    private(set) var method: LocalProbeMethod = .icmp
    private var settleUntil: TimeInterval?
    private(set) var unavailableReason: String?

    mutating func reset() { self = LocalHealthTracker() }
    mutating func settle(at now: TimeInterval = HealthTracker.now()) {
        settleUntil = now + Health.settleLimit
    }

    mutating func record(_ outcome: Latency.PingOutcome, method: LocalProbeMethod = .icmp, at: TimeInterval = HealthTracker.now()) {
        if self.method != method {
            samples.removeAll(); hasAnswered = false
            unavailableReason = nil; self.method = method
        }
        samples.removeAll { at - $0.at > Health.window }
        let ms: Double?
        switch outcome {
        case .unmeasured:
            unavailableReason = "probe unavailable"
            return
        case .reply(let reply):
            guard let valid = finiteNonNeg(reply.ms) else { return }
            ms = valid; hasAnswered = true; settleUntil = nil
        case .lost:
            if let until = settleUntil, at < until { return }
            ms = nil
        }
        unavailableReason = hasAnswered ? nil : "router not responding to probes"
        samples.append(HealthSample(at: at, ms: ms, source: .icmp,
                                    targets: [ms.map { .wan($0) } ?? .noReply], internet: .unknown))
    }

    func report(now: TimeInterval = HealthTracker.now()) -> HealthReport? {
        guard hasAnswered else { return nil }
        return Health.evaluate(samples.filter { now - $0.at <= Health.window && $0.at <= now + 1 }, now: now)
    }

    func menuTitle(router: String?, report: HealthReport?) -> String {
        guard router != nil else { return "Local health: unavailable (no local router)" }
        guard let h = report else {
            return unavailableReason.map { "Local health: unavailable (\($0))" } ?? "Local health: measuring…"
        }
        var parts = [method.label, String(format: "loss %.0f%%", h.loss * 100)]
        if let j = h.jitterMs { parts.append(String(format: "jitter %.0fms", j)) }
        if let l = h.latencyMs { parts.append(String(format: "latency %.0fms", l)) }
        return "Local health: \(h.score)% (\(parts.joined(separator: ", ")))"
    }
}

struct LocalRouter: Equatable {
    var interface: String
    var address: String

    /// netstat's default routes retain the underlying physical interface when a VPN owns
    /// the global default. Only hardware interfaces qualify; link# routes are not routers.
    static func select(ipv4: String, ipv6: String, hardware: Set<String>, preferred: String?) -> LocalRouter? {
        func routes(_ text: String) -> [LocalRouter] {
            text.split(separator: "\n").compactMap { line in
                let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard fields.count >= 4, fields[0] == "default", fields[2].contains("G"),
                      let iface = fields.dropFirst(3).first(where: { hardware.contains($0) }),
                      !fields[1].hasPrefix("link#") else { return nil }
                var address = fields[1]
                // CLAT's synthetic IPv4 gateway is not the physical router.
                guard address != "192.0.0.1" else { return nil }
                if address.lowercased().hasPrefix("fe80:"), !address.contains("%") { address += "%" + iface }
                return LocalRouter(interface: iface, address: address)
            }
        }
        let candidates = routes(ipv4) + routes(ipv6)
        return candidates.first(where: { $0.interface == preferred }) ?? candidates.first
    }
}

func resolveLocalRouter(preferred: String?, ports: [String: String]) -> LocalRouter? {
    let v4 = runProc("/usr/sbin/netstat", ["-rn", "-f", "inet"]) ?? ""
    let v6 = runProc("/usr/sbin/netstat", ["-rn", "-f", "inet6"]) ?? ""
    return LocalRouter.select(ipv4: v4, ipv6: v6, hardware: Set(ports.keys), preferred: preferred)
}
