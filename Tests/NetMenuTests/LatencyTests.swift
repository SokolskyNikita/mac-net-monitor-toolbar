import Testing
@testable import NetMenu

@Suite struct InternetAccessTests {
    @Test func ordinaryPagesAreAccepted() {
        #expect(Latency.InternetSite.example.accepts(status: 200,
            body: "<html><title>Example Domain</title><h1>Example Domain</h1></html>"))
        #expect(Latency.InternetSite.google.accepts(status: 200,
            body: "User-agent: *\nUser-agent: Yandex\nDisallow: /search\n"))
    }

    @Test(arguments: Latency.InternetSite.allCases)
    func portalAndAllowlistedConnectivityPagesAreRejected(site: Latency.InternetSite) {
        for body in ["", "<html>Sign in to United Wi-Fi</html>",
                     "<TITLE>Success</TITLE><BODY>Success</BODY>", "fl=123\nh=1.1.1.1\ncolo=ORD\n"] {
            #expect(!site.accepts(status: 200, body: body))
        }
        for status in [0, 204, 302, 403, 511] {
            #expect(!site.accepts(status: status,
                body: "User-agent: *\nDisallow: /search\n<title>Example Domain</title><h1>Example Domain</h1>"))
        }
    }

    @Test func pingAndAppleSuccessDoNotProveInternetAccess() {
        let r = Latency.decide(echoes: [.init(ms: 657, hops: 10)], gatewayMs: nil,
            portal: .internet, internetChecks: ["example.com": false, "www.google.com": false],
            httpFallback: { Issue.record("ping should remain the latency source"); return nil })
        #expect(r.ms == 657)
        #expect(r.source == .icmp)
        #expect(!r.internetReachable)
    }

    @Test func oneWorkingSiteIsEnough() {
        let r = Latency.decide(echoes: [], gatewayMs: nil, portal: .unknown,
            internetChecks: ["example.com": false, "www.google.com": true], httpFallback: { nil })
        #expect(r.internetReachable)
    }

    @Test func cloudflareTraceDoesNotProveOrdinaryInternetAccess() {
        let r = Latency.decide(echoes: [], gatewayMs: nil, portal: .internet,
            internetChecks: ["example.com": false, "www.google.com": false], httpFallback: { 700 })
        #expect(r.ms == 700)
        #expect(r.source == .http)
        #expect(!r.internetReachable)
    }

    @Test func portalWithoutWanPingSkipsFallback() {
        let r = Latency.decide(echoes: [.init(ms: 1, hops: 1)], gatewayMs: nil, portal: .portal,
            internetChecks: [:], httpFallback: { Issue.record("portal must skip fallback"); return nil })
        #expect(r.ms == nil)
        #expect(!r.internetReachable)
    }

    @Test func failedHelperCannotReturnSuccessfulOutput() {
        #expect(runProc("/bin/sh", ["-c", "printf 200; exit 1"], requireSuccess: true) == nil)
        #expect(runProc("/bin/sh", ["-c", "printf 200"], requireSuccess: true) == "200")
    }
}

@Suite struct CaptivePortalTests {
    @Test func appleSuccessPageIsInternet() {
        let body = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"
        #expect(Latency.classifyPortal(status: 200, body: body) == .internet)
    }

    @Test func loginPageIsPortal() {
        let body = "<html><head><title>Hilton Honors</title></head><body>Sign in to use the internet</body></html>"
        #expect(Latency.classifyPortal(status: 200, body: body) == .portal)
    }

    @Test(arguments: [302, 511])
    func interceptStatusIsPortal(status: Int) {
        #expect(Latency.classifyPortal(status: status, body: "") == .portal)
    }

    @Test func noResponseIsUnknown() {
        #expect(Latency.classifyPortal(status: 0, body: "") == .unknown)
    }

    @Test func emptyOkIsUnknown() {
        #expect(Latency.classifyPortal(status: 200, body: "") == .unknown)
    }
}

@Suite struct EchoJudgeTests {
    @Test func farEchoIsWan() {
        let r = Latency.EchoReply(ms: 40, hops: 12)
        #expect(Latency.judge(r, gatewayMs: nil) == .wan(40))
    }

    @Test func nearbyEchoIsOnPath() {
        let r = Latency.EchoReply(ms: 2, hops: 2)
        #expect(Latency.judge(r, gatewayMs: nil) == .onPath)
    }

    @Test func gatewaySpeedEchoIsOnPath() {
        let r = Latency.EchoReply(ms: 6, hops: 5)
        #expect(Latency.judge(r, gatewayMs: 4) == .onPath)
    }

    @Test func missingTtlOrReplyIsLost() {
        #expect(Latency.judge(Latency.EchoReply(ms: 30, hops: nil), gatewayMs: nil) == .noReply)
        #expect(Latency.judge(nil, gatewayMs: nil) == .noReply)
    }

    @Test(arguments: [(64, 0), (57, 7), (118, 10), (250, 5)])
    func hopsFromTtl(ttl: Int, hops: Int) {
        #expect(Latency.inferredHops(ttl: ttl) == hops)
    }
}

@Suite struct DecideTests {
    let far = Latency.EchoReply(ms: 25, hops: 10)
    let slow = Latency.EchoReply(ms: 90, hops: 12)
    let near = Latency.EchoReply(ms: 1, hops: 1)

    @Test func publishesFastestWanEcho() {
        let r = Latency.decide(echoes: [slow, far, near, nil], gatewayMs: nil, portal: .internet, internetChecks: ["example.com": true],
                               httpFallback: { Issue.record("fallback must not run"); return nil })
        #expect(r.ms == 25)
        #expect(r.source == .icmp)
        #expect(r.rejected == 1)
        #expect(r.failed == 1)
        #expect(r.total == 4)
    }

    @Test func loginWallPreservesWanPing() {
        let r = Latency.decide(echoes: [far, near], gatewayMs: nil, portal: .portal, internetChecks: ["example.com": false],
                               httpFallback: { Issue.record("fallback must not run"); return 1363 })
        #expect(r.ms == 25)
        #expect(r.source == .icmp)
        #expect(r.captive)
        #expect(!r.internetReachable)
        #expect(r.rejected == 1)
    }

    @Test func fallsBackToHttpTrace() {
        let r = Latency.decide(echoes: [near, nil], gatewayMs: nil, portal: .unknown, internetChecks: ["example.com": false], httpFallback: { 70 })
        #expect(r.ms == 70)
        #expect(r.source == .http)
    }

    @Test func nothingUsableCountsAsFailure() {
        let r = Latency.decide(echoes: [nil], gatewayMs: nil, portal: .unknown, internetChecks: ["example.com": false], httpFallback: { nil })
        #expect(r.ms == nil)
        #expect(r.failed == 2)
    }
}

@Suite struct LatencyWindowTests {
    // Hotel minute, 2026-09-24T10:48:33Z: these two samples, and no others.
    static let icmp = 25.364999999999998
    static let handshake = 1363.3949756622314

    func shown(_ pairs: [(Double, String)]) -> Double? {
        var samples: [Double] = []
        var src: String?
        for (ms, s) in pairs {
            pushLatency(ms, src: s, into: &samples, source: &src, limit: displayLatWindow)
        }
        return median(samples)
    }

    @Test func blendedMedianReproducesPhantom694() throws {
        let phantom = try #require(median([Self.icmp, Self.handshake]))
        #expect(abs(phantom - 694.3799878311157) < 0.001)
    }

    @Test func handshakeDoesNotAverageWithIcmp() {
        #expect(shown([(Self.icmp, "icmp"), (Self.handshake, "tls")]) == Self.handshake)
    }

    @Test func laterIcmpReplacesHandshake() {
        #expect(shown([(Self.handshake, "tls"), (Self.icmp, "icmp")]) == Self.icmp)
    }

    @Test func sameSourceKeepsWindowCapped() {
        let pairs = (1...(displayLatWindow + 3)).map { (Double($0), "icmp") }
        var samples: [Double] = []
        var src: String?
        for (ms, s) in pairs {
            pushLatency(ms, src: s, into: &samples, source: &src, limit: displayLatWindow)
        }
        #expect(samples.count == displayLatWindow)
        #expect(samples.first == 4)
    }
}
