// WAN RTT measurement that survives captive portals, SYN proxies, and TLS MITM.
//
// Threats we have actually hit:
// - Inflight/hotel Wi‑Fi SYN-ACKs 1.1.1.1:443 locally (11–80ms) while ICMP is 700–1700ms.
// - Gateway ICMP is often "no route" / permission-denied, so "matches gateway" is missing.
// - Popular DNS IPs are intercepted at 1–3 hops; google.com still echoes for real.
// - Single ICMP on a 25%+ loss sat link fails a cycle and the old code then published TCP.
// Never publish a connect time unless TLS/HTTP corroborates it.

import Foundation
import Network

struct PingResult {
    var ms: Double?
    var hops: Int?
    var rejected: Bool
    var failed: Bool
}

struct WanProbe {
    var ms: Double?
    var src: String?
    var rejected: Int
    var failed: Int
    var total: Int
    var gwMs: Double?
}

enum Latency {
    static let ipTargets = [Host.cloudflareDNS, Host.cloudflareDNS2, Host.googleDNS, Host.quad9]
    static let hostTargets = [Host.google]
    static var icmpTargets: [String] { ipTargets + hostTargets }

    /// Satellite RTT is often 600–2000ms; a 1s cap dropped real replies.
    static let icmpTimeoutMs = "8000"
    static let gatewayTimeoutMs = "1000"
    static let tcpWait: TimeInterval = 4
    static let tlsWait: TimeInterval = 12
    static let httpWait: TimeInterval = 15

    private static let tcpHost = Host.cloudflareDNS
    private static let tlsHost = Host.cloudflare
    private static let httpsPort: UInt16 = 443

    private static let timeRe = try? NSRegularExpression(pattern: #"time=([0-9.]+)"#)
    private static let ttlRe = try? NSRegularExpression(pattern: #"ttl=([0-9]+)"#)

    private static let httpSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = httpWait
        c.timeoutIntervalForResource = httpWait
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c)
    }()

    static func inferredHops(ttl: Int) -> Int {
        let initial = [64, 128, 255].filter { $0 >= ttl }.min() ?? 255
        return initial - ttl
    }

    /// Onboard/captive responders sit 1–3 hops out, or answer about as fast as the gateway.
    static func isOnPathEcho(ms: Double, hops: Int?, gatewayMs: Double?) -> Bool {
        if let hops, hops <= 3 { return true }
        if let gw = gatewayMs, ms <= gw + 15, (hops ?? 99) <= 6 { return true }
        return false
    }

    /// LAN-hop RTT — only when we actually measured the gateway.
    static func isGatewayLike(_ ms: Double, gatewayMs: Double?) -> Bool {
        guard let gw = gatewayMs else { return false }
        return ms <= max(gw * 3, gw + 20)
    }

    /// Cloudflare /cdn-cgi/trace — captive HTML and cached junk will not match.
    static func isCloudflareTrace(_ body: String) -> Bool {
        (body.contains("\nh=") || body.hasPrefix("fl=")) && body.contains("colo=")
    }

    /// Prefer a probe that crossed the WAN over a local SYN-ACK / MITM handshake.
    static func pickFallback(tcp: Double?, tls: Double?, http: Double?, gatewayMs: Double?) -> (ms: Double, src: String)? {
        if let tcp, let tls, tls > max(tcp * 3, tcp + 80) { return (tls, "tls") }
        if let tcp, let http, http > max(tcp * 3, tcp + 80) { return (http, "http") }
        if let tls, !isGatewayLike(tls, gatewayMs: gatewayMs) { return (tls, "tls") }
        if let http, !isGatewayLike(http, gatewayMs: gatewayMs) { return (http, "http") }
        // TCP connect is the last resort, and only when the gateway is known and this is not it.
        if let tcp, gatewayMs != nil, !isGatewayLike(tcp, gatewayMs: gatewayMs) {
            return (tcp, "tcp")
        }
        return nil
    }

    static func pingHost(_ host: String, timeoutMs: String, honesty: Bool) -> PingResult {
        let procTimeout = max(3.0, ((Double(timeoutMs) ?? 1000) / 1000.0) + 2.0)
        guard let out = runProc("/sbin/ping", ["-c", "1", "-W", timeoutMs, "-s", "16", host], timeout: procTimeout),
              let timeRe else {
            return PingResult(ms: nil, hops: nil, rejected: false, failed: true)
        }
        let range = NSRange(out.startIndex..., in: out)
        guard let tm = timeRe.firstMatch(in: out, range: range), let tr = Range(tm.range(at: 1), in: out),
              let raw = Double(out[tr]), let ms = finiteNonNeg(raw) else {
            return PingResult(ms: nil, hops: nil, rejected: false, failed: true)
        }
        var hops: Int?
        if let ttlRe,
           let ttlm = ttlRe.firstMatch(in: out, range: range), let tlr = Range(ttlm.range(at: 1), in: out),
           let ttl = Int(out[tlr]) {
            hops = inferredHops(ttl: ttl)
        }
        if !honesty { return PingResult(ms: ms, hops: hops, rejected: false, failed: false) }
        guard let hops else {
            return PingResult(ms: nil, hops: nil, rejected: false, failed: true)
        }
        if hops <= 3 { return PingResult(ms: nil, hops: hops, rejected: true, failed: false) }
        return PingResult(ms: ms, hops: hops, rejected: false, failed: false)
    }

    static func connectProbe(host: String, port: UInt16, using params: NWParameters, wait: TimeInterval) -> Double? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let conn = NWConnection(host: .init(host), port: nwPort, using: params)
        let sem = DispatchSemaphore(value: 0)
        let state = NSLock()
        var ok = false
        var finished = false
        let t0 = Date()
        conn.stateUpdateHandler = { s in
            state.lock()
            defer { state.unlock() }
            guard !finished else { return }
            switch s {
            case .ready:
                ok = true; finished = true; sem.signal()
            case .failed, .cancelled:
                finished = true; sem.signal()
            default: break
            }
        }
        conn.start(queue: .global(qos: .utility))
        _ = sem.wait(timeout: .now() + wait)
        conn.cancel()
        state.lock(); let success = ok; state.unlock()
        guard success, let ms = finiteNonNeg(Date().timeIntervalSince(t0) * 1000) else { return nil }
        return ms
    }

    static func tcpProbe() -> Double? {
        connectProbe(host: tcpHost, port: httpsPort, using: .tcp, wait: tcpWait)
    }

    static func tlsProbe() -> Double? {
        connectProbe(host: tlsHost, port: httpsPort, using: .tls, wait: tlsWait)
    }

    /// Full HTTPS GET — first byte from a verified origin, not a SYN-ACK or local MITM finished.
    static func httpProbe() -> Double? {
        let urls = [
            "https://\(Host.cloudflareDNS)/cdn-cgi/trace?n=\(UUID().uuidString)",
            "https://cloudflare.com/cdn-cgi/trace?n=\(UUID().uuidString)"
        ]
        for url in urls {
            if let ms = httpTrace(url) { return ms }
        }
        return nil
    }

    private static func httpTrace(_ url: String) -> Double? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = httpWait
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let t0 = Date()
        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        var status = 0
        let task = httpSession.dataTask(with: req) { data, resp, _ in
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            body = data
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + httpWait + 2) == .timedOut {
            task.cancel()
            return nil
        }
        guard (200..<300).contains(status),
              let data = body, let text = String(data: data, encoding: .utf8),
              isCloudflareTrace(text),
              let ms = finiteNonNeg(Date().timeIntervalSince(t0) * 1000) else { return nil }
        return ms
    }

    static func measure(gateway: String?, probeGateway: Bool) -> WanProbe {
        let lock = NSLock()
        let group = DispatchGroup()
        var gw: Double?
        if probeGateway, let g = gateway {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let r = pingHost(g, timeoutMs: gatewayTimeoutMs, honesty: false)
                lock.lock(); gw = r.ms; lock.unlock()
                group.leave()
            }
        }
        var replies: [PingResult] = []
        for h in icmpTargets {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let r = pingHost(h, timeoutMs: icmpTimeoutMs, honesty: true)
                lock.lock(); replies.append(r); lock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 14)

        var honest: [Double] = [], rejected = 0, failed = 0
        let total = replies.count
        for r in replies {
            if r.rejected { rejected += 1 }
            else if r.failed { failed += 1 }
            else if let m = r.ms {
                if isOnPathEcho(ms: m, hops: r.hops, gatewayMs: gw) { rejected += 1 }
                else { honest.append(m) }
            }
        }

        var ms: Double?, src: String?
        // Best honest ICMP — max() biased the menu bar to wakeup / worse-path spikes.
        if let m = honest.min() {
            ms = m; src = "icmp"
        } else {
            var tcp: Double?, tls: Double?, http: Double?
            let fb = DispatchGroup()
            fb.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let v = tcpProbe(); lock.lock(); tcp = v; lock.unlock(); fb.leave()
            }
            fb.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let v = tlsProbe(); lock.lock(); tls = v; lock.unlock(); fb.leave()
            }
            fb.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let v = httpProbe(); lock.lock(); http = v; lock.unlock(); fb.leave()
            }
            _ = fb.wait(timeout: .now() + 16)
            if let chosen = pickFallback(tcp: tcp, tls: tls, http: http, gatewayMs: gw) {
                ms = chosen.ms; src = chosen.src
            } else {
                failed += 1
            }
        }
        return WanProbe(ms: ms, src: src, rejected: rejected, failed: failed, total: max(total, 1), gwMs: gw)
    }
}

func probeWAN(gateway: String?, probeGateway: Bool) -> WanProbe {
    Latency.measure(gateway: gateway, probeGateway: probeGateway)
}
