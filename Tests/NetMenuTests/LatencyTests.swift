import Testing
@testable import NetMenu

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
        let r = Latency.decide(echoes: [slow, far, near, nil], gatewayMs: nil, portal: .internet,
                               httpFallback: { Issue.record("fallback must not run"); return nil })
        #expect(r.ms == 25)
        #expect(r.source == .icmp)
        #expect(r.rejected == 1)
        #expect(r.failed == 1)
        #expect(r.total == 4)
    }

    @Test func loginWallPublishesNothing() {
        let r = Latency.decide(echoes: [far, near], gatewayMs: nil, portal: .portal,
                               httpFallback: { Issue.record("fallback must not run"); return 1363 })
        #expect(r.ms == nil)
        #expect(r.captive)
        #expect(r.rejected == 2)
    }

    @Test func fallsBackToHttpTrace() {
        let r = Latency.decide(echoes: [near, nil], gatewayMs: nil, portal: .unknown, httpFallback: { 70 })
        #expect(r.ms == 70)
        #expect(r.source == .http)
    }

    @Test func nothingUsableCountsAsFailure() {
        let r = Latency.decide(echoes: [nil], gatewayMs: nil, portal: .unknown, httpFallback: { nil })
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
