// WAN round-trip time that stays honest on captive portals, SYN proxies, and TLS MITM.
//
// One cycle runs every probe in parallel, then `decide` picks what to publish:
//   1. Apple's captive check shows a login page  → publish nothing.
//   2. Some ICMP echo came from beyond the local path → publish the fastest one.
//   3. Otherwise a Cloudflare trace over HTTPS answered → publish its time-to-first-byte.
//   4. Otherwise → publish nothing.
//
// Networks that shaped these rules:
// - Inflight/hotel Wi‑Fi SYN-ACKs 1.1.1.1:443 locally (11–80ms) while ICMP is 700–1700ms,
//   so a bare TCP or TLS connect time is never published.
// - Popular DNS IPs are answered 1–3 hops out by the portal; google.com still echoes for real.
// - Gateway ICMP is often blocked, so "as fast as the gateway" cannot be the only on-path test.
// - A hotel login wall answered one ICMP echo (25ms) and one TLS connect (~1363ms); their
//   median, 694ms, sat in the menu bar although no probe measured it.

import Foundation

// MARK: - Results

enum LatencySource: String {
    case icmp
    case http
}

struct WanProbe {
    var ms: Double?
    var source: LatencySource?
    /// ICMP echoes discarded as answered by the local path, or by anything behind a login wall.
    var rejected: Int
    /// Probes that got no usable answer.
    var failed: Int
    /// ICMP targets probed this cycle; denominator for the logged loss rate.
    var total: Int
    var gatewayMs: Double?
    /// A login wall answered the captive check. The caller should drop the displayed RTT.
    var captive: Bool
}

enum Latency {

    // MARK: - Tuning

    static let icmpTargets = [Host.cloudflareDNS, Host.cloudflareDNS2, Host.googleDNS, Host.quad9, Host.google]
    /// Satellite RTT is often 600–2000ms; a 1s cap dropped real replies.
    static let icmpTimeoutMs = 8000
    static let gatewayTimeoutMs = 1000
    static let captiveWait: TimeInterval = 4
    static let httpWait: TimeInterval = 15
    /// Upper bound for the parallel phase: the slowest ping plus process-kill slack.
    static let cycleWait: TimeInterval = 14

    /// Echoes from this few hops out are the portal or onboard router, not the target.
    static let maxLocalHops = 3

    // MARK: - Measurement cycle

    /// Pass `gateway: nil` to skip the gateway ping (e.g. in `--sample`, which avoids Local Network TCC).
    static func measure(gateway: String?) -> WanProbe {
        let found = runParallelProbes(gateway: gateway)
        return decide(echoes: found.echoes, gatewayMs: found.gatewayMs, portal: found.portal,
                      httpFallback: httpProbe)
    }

    /// Pure decision step. `httpFallback` runs only when no ICMP echo can be published.
    static func decide(echoes: [EchoReply?], gatewayMs: Double?, portal: Captive,
                       httpFallback: () -> Double?) -> WanProbe {
        var wan: [Double] = [], rejected = 0, failed = 0
        for echo in echoes {
            switch judge(echo, gatewayMs: gatewayMs) {
            case .wan(let ms): wan.append(ms)
            case .onPath: rejected += 1
            case .noReply: failed += 1
            }
        }
        var probe = WanProbe(ms: nil, source: nil, rejected: rejected, failed: failed,
                             total: max(echoes.count, 1), gatewayMs: gatewayMs, captive: false)

        if portal == .portal {
            probe.rejected += wan.count
            probe.captive = true
            return probe
        }
        // Fastest echo: slower ones are wakeup spikes or worse paths, not the link.
        if let best = wan.min() {
            probe.ms = best; probe.source = .icmp
        } else if let ms = httpFallback() {
            probe.ms = ms; probe.source = .http
        } else {
            probe.failed += 1
        }
        return probe
    }

    private static func runParallelProbes(gateway: String?) -> (echoes: [EchoReply?], gatewayMs: Double?, portal: Captive) {
        let group = DispatchGroup()
        let echoes = Locked<[EchoReply?]>([])
        let gatewayMs = Locked<Double?>(nil)
        let portal = Locked(Captive.unknown)

        func run(_ work: @escaping () -> Void) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { work(); group.leave() }
        }
        if let gateway {
            run { gatewayMs.set(ping(gateway, timeoutMs: gatewayTimeoutMs)?.ms) }
        }
        for host in icmpTargets {
            run { let r = ping(host, timeoutMs: icmpTimeoutMs); echoes.mutate { $0.append(r) } }
        }
        run { portal.set(detectPortal()) }

        _ = group.wait(timeout: .now() + cycleWait)
        return (echoes.value, gatewayMs.value, portal.value)
    }

    // MARK: - ICMP

    struct EchoReply {
        var ms: Double
        var hops: Int?
    }

    enum EchoVerdict: Equatable {
        case wan(Double)
        case onPath
        case noReply
    }

    /// One `/sbin/ping`. Nil when nothing came back in time.
    static func ping(_ host: String, timeoutMs: Int) -> EchoReply? {
        let procTimeout = max(3.0, Double(timeoutMs) / 1000 + 2)
        guard let out = runProc("/sbin/ping", ["-c", "1", "-W", String(timeoutMs), "-s", "16", host],
                                timeout: procTimeout),
              let raw = firstCapture(timeRe, in: out).flatMap(Double.init),
              let ms = finiteNonNeg(raw) else { return nil }
        let hops = firstCapture(ttlRe, in: out).flatMap(Int.init).map(inferredHops)
        return EchoReply(ms: ms, hops: hops)
    }

    /// A reply without a TTL cannot be placed on the path, so it counts as lost.
    static func judge(_ reply: EchoReply?, gatewayMs: Double?) -> EchoVerdict {
        guard let reply, let hops = reply.hops else { return .noReply }
        return isOnPathEcho(ms: reply.ms, hops: hops, gatewayMs: gatewayMs) ? .onPath : .wan(reply.ms)
    }

    /// Portal and onboard responders sit a few hops out, or answer about as fast as the gateway.
    static func isOnPathEcho(ms: Double, hops: Int, gatewayMs: Double?) -> Bool {
        if hops <= maxLocalHops { return true }
        if let gw = gatewayMs, ms <= gw + 15, hops <= 6 { return true }
        return false
    }

    /// Hosts start TTL at 64, 128, or 255; hops = distance down to the observed value.
    static func inferredHops(ttl: Int) -> Int {
        let initial = [64, 128, 255].filter { $0 >= ttl }.min() ?? 255
        return initial - ttl
    }

    private static let timeRe = try? NSRegularExpression(pattern: #"time=([0-9.]+)"#)
    private static let ttlRe = try? NSRegularExpression(pattern: #"ttl=([0-9]+)"#)

    private static func firstCapture(_ re: NSRegularExpression?, in text: String) -> String? {
        guard let re,
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: - Captive portal

    enum Captive: Equatable {
        case internet
        case portal
        /// Check timed out or was filtered. Never blanks the reading on its own.
        case unknown
    }

    /// A login wall intercepts this; the open internet returns a tiny Success page.
    private static let captiveURL = "http://captive.apple.com/hotspot-detect.html"

    /// Redirects are not followed: a 302 to the hotel login page is the wall itself.
    static func detectPortal() -> Captive {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("netmenu-captive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        guard let out = runProc("/usr/bin/curl", [
            "-sS",
            "--max-time", String(Int(captiveWait)),
            "--max-redirs", "0",
            "-A", "CaptiveNetworkSupport/1.0 wispr",
            "-o", bodyURL.path,
            "-w", "%{http_code}",
            captiveURL
        ], timeout: captiveWait + 2) else { return .unknown }
        let status = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return classifyPortal(status: status, body: readPrefix(of: bodyURL, bytes: 2048))
    }

    /// 200 + Success page = internet. 200 with any other body, 511, or a redirect = login wall.
    static func classifyPortal(status: Int, body: String) -> Captive {
        if status == 200 && isAppleSuccessPage(body) { return .internet }
        if status == 200 && body.isEmpty { return .unknown }
        if status == 200 || status == 511 || (300..<400).contains(status) { return .portal }
        return .unknown
    }

    static func isAppleSuccessPage(_ body: String) -> Bool {
        body.utf8.count <= 512
            && body.range(of: "<TITLE>Success</TITLE>", options: .caseInsensitive) != nil
            && body.range(of: "<BODY>Success</BODY>", options: .caseInsensitive) != nil
    }

    private static func readPrefix(of url: URL, bytes: Int) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        return String(data: fh.readData(ofLength: bytes), encoding: .utf8) ?? ""
    }

    // MARK: - HTTPS trace fallback

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

    /// Time to a verified Cloudflare trace body — a local SYN-ACK or MITM handshake cannot produce one.
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

    /// Captive HTML and cached junk will not match.
    static func isCloudflareTrace(_ body: String) -> Bool {
        (body.contains("\nh=") || body.hasPrefix("fl=")) && body.contains("colo=")
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
              isCloudflareTrace(text) else { return nil }
        return finiteNonNeg(Date().timeIntervalSince(t0) * 1000)
    }
}

/// Value shared between probe threads. A probe that finishes after `cycleWait` writes into a
/// snapshot nobody reads again, so it is dropped rather than published late.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ v: T) { lock.lock(); stored = v; lock.unlock() }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&stored); lock.unlock() }
}
