// WAN round-trip time that stays honest on captive portals, SYN proxies, and TLS MITM.
//
// One cycle runs every probe in parallel, then `decide` picks what to publish:
//   1. Some ICMP echo came from beyond the local path → publish the fastest one.
//   2. Apple's captive check shows a login page → skip the HTTPS latency fallback.
//   3. Otherwise a Cloudflare trace over HTTPS answered → publish its time-to-first-byte.
//   4. Otherwise → publish nothing.
//
// A probe this Mac could not run (helper failed to launch, DNS could not resolve a ping target)
// is `unmeasured`, never lost: connection health must not blame the network for a local fault.
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

enum InternetStatus: String {
    case reachable
    case unreachable
    /// No website check could run this cycle.
    case unknown
}

struct WanProbe {
    var ms: Double?
    var source: LatencySource?
    /// ICMP echoes discarded as answered by the local path.
    var rejected: Int
    /// Probes that got no usable answer, plus one when nothing could be published; at most `total`.
    var failed: Int
    /// ICMP targets measured this cycle; denominator for the logged loss rate.
    var total: Int
    /// One verdict per echo, in the order the echoes were passed to `decide`.
    var verdicts: [Latency.EchoVerdict] = []
    var gatewayMs: Double?
    /// A login wall answered the captive check. This does not invalidate a WAN ping.
    var captive: Bool
    /// Ordinary HTTPS sites, checked independently of ping and captive-portal allowlists.
    /// Sites whose check could not run are absent.
    var internetChecks: [String: Bool]
    /// Per-probe detail for the diagnostic log.
    var details: [String] = []

    var internetReachable: Bool { internetChecks.values.contains(true) }

    var internet: InternetStatus {
        if internetReachable { return .reachable }
        return internetChecks.isEmpty ? .unknown : .unreachable
    }

    /// False when nothing at all could be measured; such a cycle says nothing about the network.
    var measured: Bool {
        ms != nil || !internetChecks.isEmpty || verdicts.contains { $0 != .unmeasured }
    }

    /// Anything beyond the local path answered.
    var anySuccess: Bool {
        ms != nil || internetReachable || verdicts.contains { if case .wan = $0 { return true } else { return false } }
    }

    /// Failed website checks are confirmed by this cycle alone when nothing else got through either,
    /// or a login wall explains them.
    var corroboratesOutage: Bool { ms == nil || captive }

    var logLine: String {
        var parts = details
        parts.append("gw=" + (gatewayMs.map { String(format: "%.1fms", $0) } ?? "-"))
        parts.append("captive=\(captive)")
        parts.append("published=" + (ms.map { String(format: "%.1fms/%@", $0, source?.rawValue ?? "?") } ?? "none"))
        parts.append("internet=\(internet.rawValue)")
        return parts.joined(separator: " ")
    }
}

enum Latency {

    // MARK: - Tuning

    static let icmpTargets = [Host.cloudflareDNS, Host.cloudflareDNS2, Host.googleDNS, Host.quad9, Host.google]
    /// Satellite RTT is often 600–2000ms; a 1s cap dropped real replies.
    static let icmpTimeoutMs = 8000
    static let gatewayTimeoutMs = 1000
    static let captiveWait: TimeInterval = 4
    static let httpWait: TimeInterval = 15
    static let internetWait: TimeInterval = 8
    /// Upper bound for the parallel phase: the slowest ping plus process-kill slack.
    static let cycleWait: TimeInterval = 14

    /// Echoes from this few hops out are the portal or onboard router, not the target.
    static let maxLocalHops = 3

    // MARK: - Measurement cycle

    /// While everything answers, the website and captive checks (two HTTPS handshakes and three
    /// helper processes) run every this many cycles; any sign of trouble makes them run every cycle.
    static let websiteCheckEvery = 5

    /// Pure: whether the next cycle should fetch the websites and the captive check.
    static func websiteCheckDue(cyclesSinceCheck: Int, lastWebsites: InternetStatus, previous: WanProbe?,
                                networkChanged: Bool) -> Bool {
        guard let p = previous, !networkChanged, lastWebsites == .reachable else { return true }
        if cyclesSinceCheck + 1 >= websiteCheckEvery { return true }
        let trouble = p.ms == nil || p.captive
            || p.verdicts.contains { $0 == .noReply || $0 == .unmeasured }
        return trouble
    }

    /// Pass `gateway: nil` to skip the gateway ping (e.g. in `--sample`, which avoids Local Network TCC).
    /// With `checkWebsites: false` the cycle reports `internet == .unknown` and an unknown portal.
    static func measure(gateway: String?, checkWebsites: Bool = true) -> WanProbe {
        let found = runParallelProbes(gateway: gateway, checkWebsites: checkWebsites)
        var probe = decide(echoes: found.echoes, unmeasured: found.unmeasured, gatewayMs: found.gatewayMs,
                           portal: found.portal, internetChecks: found.internetChecks,
                           httpFallback: httpProbe)
        probe.details = found.details
        return probe
    }

    /// Pure decision step. `httpFallback` runs only when no ICMP echo can be published.
    /// `unmeasured` holds indexes of `echoes` whose ping could not run; they are neither lost nor answered.
    static func decide(echoes: [EchoReply?], unmeasured: Set<Int> = [], gatewayMs: Double?, portal: Captive,
                       internetChecks: [String: Bool],
                       httpFallback: () -> Double?) -> WanProbe {
        var wan: [Double] = [], rejected = 0, failed = 0
        let verdicts = echoes.enumerated().map { i, echo in
            unmeasured.contains(i) ? .unmeasured : judge(echo, gatewayMs: gatewayMs)
        }
        for verdict in verdicts {
            switch verdict {
            case .wan(let ms): wan.append(ms)
            case .onPath: rejected += 1
            case .noReply: failed += 1
            case .unmeasured: break
            }
        }
        let total = max(verdicts.filter { $0 != .unmeasured }.count, 1)
        var probe = WanProbe(ms: nil, source: nil, rejected: rejected, failed: failed,
                             total: total, verdicts: verdicts, gatewayMs: gatewayMs,
                             captive: portal == .portal, internetChecks: internetChecks)

        // Fastest echo: slower ones are wakeup spikes or worse paths, not the link.
        if let best = wan.min() {
            probe.ms = best; probe.source = .icmp
        } else if portal != .portal, let ms = httpFallback() {
            probe.ms = ms; probe.source = .http
        } else {
            probe.failed = min(probe.failed + 1, max(total - rejected, 0))
        }
        return probe
    }

    private struct ParallelResult {
        var echoes: [EchoReply?]
        var unmeasured: Set<Int>
        var gatewayMs: Double?
        var portal: Captive
        var internetChecks: [String: Bool]
        var details: [String]
    }

    private static func runParallelProbes(gateway: String?, checkWebsites: Bool) -> ParallelResult {
        let group = DispatchGroup()
        // Indexed by target so connection health can track each host's loss separately. A probe
        // still running at `cycleWait` stays .unmeasured: it was cut off, not answered or lost.
        let echoes = Locked<[PingOutcome]>(Array(repeating: .unmeasured("cut off"), count: icmpTargets.count))
        let gatewayMs = Locked<Double?>(nil)
        let portal = Locked(Captive.unknown)
        let checks = Locked<[InternetSite: InternetCheck]>([:])

        func run(_ work: @escaping () -> Void) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { autoreleasepool { work() }; group.leave() }
        }
        if let gateway {
            run { if case .reply(let r) = ping(gateway, timeoutMs: gatewayTimeoutMs) { gatewayMs.set(r.ms) } }
        }
        for (i, host) in icmpTargets.enumerated() {
            run { let r = ping(host, timeoutMs: icmpTimeoutMs); echoes.mutate { $0[i] = r } }
        }
        if checkWebsites {
            run { portal.set(detectPortal()) }
            for site in InternetSite.allCases {
                run { let r = checkInternet(site); checks.mutate { $0[site] = r } }
            }
        }

        _ = group.wait(timeout: .now() + cycleWait)
        let pings = echoes.value, sites = checks.value
        var result = ParallelResult(echoes: [], unmeasured: [], gatewayMs: gatewayMs.value,
                                    portal: portal.value, internetChecks: [:], details: [])
        for (i, outcome) in pings.enumerated() {
            switch outcome {
            case .reply(let r):
                result.echoes.append(r)
                result.details.append(String(format: "%@=%.1fms/h%@", icmpTargets[i], r.ms, r.hops.map(String.init) ?? "?"))
            case .lost:
                result.echoes.append(nil)
                result.details.append("\(icmpTargets[i])=lost")
            case .unmeasured(let why):
                result.echoes.append(nil); result.unmeasured.insert(i)
                result.details.append("\(icmpTargets[i])=unmeasured(\(why))")
            }
        }
        for site in InternetSite.allCases where checkWebsites {
            let check = sites[site] ?? InternetCheck(outcome: .unmeasured("cut off"), seconds: cycleWait)
            switch check.outcome {
            case .ok: result.internetChecks[site.rawValue] = true
            case .failed: result.internetChecks[site.rawValue] = false
            case .unmeasured: break
            }
            result.details.append("\(site.rawValue)=\(check.summary)")
        }
        result.details.append(checkWebsites ? "portal=\(portal.value)" : "web=skipped")
        return result
    }

    // MARK: - Ordinary internet access

    enum InternetSite: String, CaseIterable {
        case example = "example.com"
        case google = "www.google.com"

        var url: String {
            switch self {
            case .example: return "https://example.com/"
            case .google: return "https://www.google.com/robots.txt"
            }
        }

        /// Require a real response body, not just DNS, a TCP/TLS handshake, or a login redirect.
        func accepts(status: Int, body: String) -> Bool {
            guard status == 200 else { return false }
            switch self {
            case .example:
                // IANA dropped the <h1> in Sept 2026; match text both page versions share.
                return body.contains("<title>Example Domain</title>") && body.contains("This domain is for use in")
            case .google:
                return body.hasPrefix("User-agent: *") && body.contains("Disallow: /search")
            }
        }
    }

    struct InternetCheck {
        enum Outcome {
            case ok
            case failed(String)
            /// The check could not run here, which says nothing about the network.
            case unmeasured(String)
        }
        var outcome: Outcome
        var seconds: TimeInterval

        var summary: String {
            let t = String(format: "%.2fs", seconds)
            switch outcome {
            case .ok: return "ok(\(t))"
            case .failed(let why): return "FAIL(\(why),\(t))"
            case .unmeasured(let why): return "unmeasured(\(why))"
            }
        }
    }

    static func checkInternet(_ site: InternetSite) -> InternetCheck {
        let t0 = Date()
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tempPrefix)internet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        // -q disables user curlrc overrides. TLS verification stays enabled; no redirects,
        // cookies, or local cache. The nonce and no-cache header also avoid proxy cache hits.
        let r = runProcess("/usr/bin/curl", [
            "-q", "-sS", "--proto", "=https", "--max-time", String(Int(internetWait)),
            "--max-redirs", "0", "--max-filesize", "65536",
            "-H", "Cache-Control: no-cache", "-H", "Accept-Encoding: identity",
            "-o", bodyURL.path, "-w", "%{http_code}",
            site.url + "?netmenu=" + UUID().uuidString
        ], timeout: internetWait + 2)
        let seconds = Date().timeIntervalSince(t0)
        func check(_ outcome: InternetCheck.Outcome) -> InternetCheck { InternetCheck(outcome: outcome, seconds: seconds) }
        switch r.outcome {
        case .launchFailed(let why): return check(.unmeasured(why))
        // curl enforces --max-time itself, so being killed means this Mac stalled, not the network.
        case .timedOut: return check(.unmeasured("curl hung"))
        case .signaled(let sig): return check(.unmeasured("curl killed by signal \(sig)"))
        case .outputIncomplete: return check(.unmeasured("curl output incomplete"))
        case .exited(let code) where code != 0:
            if isLocalCurlFailure(code: code, stderr: r.stderr) {
                return check(.unmeasured("curl \(code) local: \(r.stderr.prefix(120))"))
            }
            return check(.failed("curl \(code)"))
        case .exited: break
        }
        guard let status = Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return check(.failed("no status"))
        }
        guard site.accepts(status: status, body: readPrefix(of: bodyURL, bytes: 65536)) else {
            return check(.failed("HTTP \(status) unexpected body"))
        }
        return check(.ok)
    }

    /// curl failures caused by this Mac rather than the network: it could not start up, write the
    /// body, allocate memory, or read its CA store. Exit 56 also covers network receive errors,
    /// so the message decides. (Crashes arrive as `.signaled`, handled separately.)
    static func isLocalCurlFailure(code: Int32, stderr: String) -> Bool {
        if [2, 23, 26, 27, 77].contains(code) { return true }
        let localMessages = ["Failure writing output", "Failed writing", "Out of memory", "Too many open files",
                             "Failed to open", "Failed to create", "problem with the local"]
        return localMessages.contains { stderr.localizedCaseInsensitiveContains($0) }
    }

    /// Prefix of temporary files; stale ones from a crash are removed at launch.
    static let tempPrefix = "netmenu-"

    // MARK: - ICMP

    struct EchoReply {
        var ms: Double
        var hops: Int?
    }

    enum EchoVerdict: Equatable {
        case wan(Double)
        case onPath
        case noReply
        /// The ping could not run or its target could not be resolved; excluded from loss.
        case unmeasured
    }

    enum PingOutcome {
        case reply(EchoReply)
        case lost
        case unmeasured(String)
    }

    /// One `/sbin/ping`.
    static func ping(_ host: String, timeoutMs: Int) -> PingOutcome {
        let procTimeout = max(3.0, Double(timeoutMs) / 1000 + 2)
        let r = runProcess("/sbin/ping", ["-c", "1", "-W", String(timeoutMs), "-s", "16", host], timeout: procTimeout)
        switch r.outcome {
        case .launchFailed(let why): return .unmeasured(why)
        // ping enforces -W itself, so being killed means this Mac stalled, not the network.
        case .timedOut: return .unmeasured("ping hung")
        case .signaled(let sig): return .unmeasured("ping killed by signal \(sig)")
        case .outputIncomplete: return .unmeasured("ping output incomplete")
        // ping(8): 2 = sent but no reply. Any other failure (68 unknown host, a crash, a socket
        // error) is DNS or this Mac, not packet loss.
        case .exited(2): return .lost
        case .exited(0): break
        case .exited(let code): return .unmeasured("ping \(code)" + (r.stderr.isEmpty ? "" : ": \(r.stderr.prefix(80))"))
        }
        guard let raw = firstCapture(timeRe, in: r.stdout).flatMap(Double.init),
              let ms = finiteNonNeg(raw) else { return .unmeasured("unparsed reply") }
        let hops = firstCapture(ttlRe, in: r.stdout).flatMap(Int.init).map(inferredHops)
        return .reply(EchoReply(ms: ms, hops: hops))
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
            .appendingPathComponent("\(tempPrefix)captive-\(UUID().uuidString)")
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
        // The throwing read: readData(ofLength:) raises an uncatchable exception on I/O errors.
        let data = (try? fh.read(upToCount: bytes)) ?? nil
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
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
        // A late completion after our timeout must not race with this thread's read.
        let reply = Locked<(status: Int, body: Data?)>((0, nil))
        let task = httpSession.dataTask(with: req) { data, resp, _ in
            reply.set(((resp as? HTTPURLResponse)?.statusCode ?? 0, data))
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + httpWait + 2) == .timedOut {
            task.cancel()
            return nil
        }
        let (status, body) = reply.value
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
