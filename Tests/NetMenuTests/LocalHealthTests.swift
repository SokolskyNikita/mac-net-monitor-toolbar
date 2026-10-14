import Foundation
import Testing
@testable import NetMenu

@Suite struct LocalHealthTests {
    @Test func matchesWANFormulaAndPreservesSubmillisecondJitter() throws {
        var tracker = LocalHealthTracker()
        var samples: [HealthSample] = []
        for i in 0..<20 {
            let ms = i % 2 == 0 ? 4.0 : 4.3
            tracker.record(.reply(.init(ms: ms, hops: nil)), at: Double(i * 3))
            samples.append(.init(at: Double(i * 3), ms: ms, source: .icmp, targets: [.wan(ms)], internet: .unknown))
        }
        let report = try #require(tracker.report(now: 57))
        #expect(report == Health.evaluate(samples))
        #expect(report.score == 100)
        #expect(abs((report.jitterMs ?? 0) - 0.3) < 0.0001)
        #expect(tracker.menuTitle(router: "192.168.1.1", report: report).contains("jitter 0ms"))
    }

    @Test func neverAnsweredIsUnavailableThenLossCounts() throws {
        var tracker = LocalHealthTracker()
        for i in 0..<3 { tracker.record(.lost, at: Double(i)) }
        #expect(tracker.report(now: 2) == nil)
        #expect(tracker.menuTitle(router: "::1", report: nil).contains("not responding"))
        tracker.record(.reply(.init(ms: 4, hops: nil)), at: 3)
        let lostWeight = 1 / sqrt(3.0) + 1 / sqrt(2.0) + 1
        #expect(abs((tracker.report(now: 3)?.loss ?? 0) - lostWeight / (lostWeight + 1)) < 1e-12)
        for i in 4...65 { tracker.record(.lost, at: Double(i)) }
        #expect(tracker.report(now: 65)?.score == 0)
        #expect(tracker.report(now: 65)?.loss == 1)
        #expect(tracker.report(now: 126) == nil)
    }

    @Test func unavailableProbesDoNotBecomeLossAndResetClearsHistory() throws {
        var tracker = LocalHealthTracker()
        for i in 0..<3 { tracker.record(.reply(.init(ms: 4, hops: nil)), at: Double(i)) }
        tracker.record(.unmeasured("permission denied"), at: 3)
        #expect(tracker.report(now: 3)?.loss == 0)
        #expect(tracker.report(now: 64) == nil)
        tracker.reset()
        #expect(tracker.report(now: 3) == nil)
        tracker.settle(at: 4)
        tracker.record(.lost, at: 5)
        tracker.record(.reply(.init(ms: 4, hops: nil)), at: 6)
        tracker.record(.reply(.init(ms: 4, hops: nil)), at: 7)
        tracker.record(.reply(.init(ms: 4, hops: nil)), at: 8)
        #expect(tracker.report(now: 8)?.loss == 0)
    }

    @Test func ipv4RouterBehindVPN() {
        let router = LocalRouter.select(ipv4: """
        default link#28 UCSg utun4
        default 192.168.1.1 UGScIg en0
        """, ipv6: "default fe80::1%en0 UGcIg en0", hardware: ["en0"], preferred: "utun4")
        #expect(router == LocalRouter(interface: "en0", address: "192.168.1.1"))
    }

    @Test func clatUsesScopedIPv6AndSkipsTunnels() {
        let router = LocalRouter.select(ipv4: "default 192.0.0.1 UGScIg en0", ipv6: """
        default fd7a::1 UGcg utun4
        default fe80::abcd UGcIg en0
        default fe80::%utun0 UGcIg utun0
        """, hardware: ["en0"], preferred: "utun4")
        #expect(router == LocalRouter(interface: "en0", address: "fe80::abcd%en0"))
    }

    @Test func preferredPhysicalInterfaceWinsAndNoRouterStaysUnavailable() {
        #expect(LocalRouter.select(ipv4: "default 10.0.0.1 UGSc en0\ndefault 10.1.0.1 UGSc en5",
                                  ipv6: "", hardware: ["en0", "en5"], preferred: "en5")?.interface == "en5")
        #expect(LocalRouter.select(ipv4: "default link#28 UCSg utun4", ipv6: "",
                                  hardware: ["en0"], preferred: "utun4") == nil)
    }

    @Test func ipv6RejectsUnrelatedReplies() {
        let request: [UInt8] = [128, 0, 0, 0, 1, 2, 3, 4, 9, 8]
        var reply = request; reply[0] = 129
        #expect(IPv6Pinger.matchesReply(reply, request: request))
        reply[8] = 7
        #expect(!IPv6Pinger.matchesReply(reply, request: request))
        #expect(!IPv6Pinger.matchesReply([], request: request))
        #expect(!IPv6Pinger.matchesReply(request, request: request))
    }

    @Test func changedPhysicalRouterInvalidatesVPNIdentity() {
        var a = Identity(iface: "utun4", type: "vpn", network: "VPN", bssid: nil,
                         router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
        a.localRouter = LocalRouter(interface: "en0", address: "192.168.1.1")
        var b = a
        b.localRouter = LocalRouter(interface: "en0", address: "fe80::1%en0")
        #expect(!a.sameNetwork(as: b))
    }

    @Test func invalidIPv6IsUnmeasured() {
        guard case .unmeasured = Latency.ping("bad::router", timeoutMs: 100) else {
            Issue.record("Invalid addresses must not count as packet loss"); return
        }
    }

    @Test func ipv6LoopbackAnswers() {
        guard case .reply(let reply) = Latency.ping("::1", timeoutMs: 1000) else {
            Issue.record("IPv6 loopback should answer"); return
        }
        #expect(reply.ms >= 0 && reply.ms < 1000)
    }
}
