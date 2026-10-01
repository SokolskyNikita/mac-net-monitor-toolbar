import Darwin
import Foundation
import Testing
@testable import NetMenu

/// An IPv4 packet wrapping `icmp`, as an ICMP datagram socket delivers it.
private func ipv4(_ icmp: [UInt8], ttl: UInt8 = 55, proto: UInt8 = 1) -> [UInt8] {
    var header: [UInt8] = [0x45, 0, 0, UInt8(20 + icmp.count), 0, 0, 0, 0, ttl, proto, 0, 0,
                           1, 1, 1, 1, 192, 168, 8, 100]
    let c = ICMPPinger.checksum(header[...])
    header[10] = UInt8(c >> 8); header[11] = UInt8(c & 0xff)
    return header + icmp
}

private func reply(id: UInt16, seq: UInt16, payload: [UInt8]) -> [UInt8] {
    var r = ICMPPinger.echoRequest(identifier: id, sequence: seq, payload: payload)
    r[0] = 0  // echo reply
    r[2] = 0; r[3] = 0
    let c = ICMPPinger.checksum(r[...])
    r[2] = UInt8(c >> 8); r[3] = UInt8(c & 0xff)
    return r
}

@Suite struct ICMPPacketTests {
    let payload: [UInt8] = Array(0..<16)

    @Test func checksumMatchesRFC1071Example() {
        // RFC 1071 §3: 0001 f203 f4f5 f6f7 sums to 0xddf2; the checksum is its complement.
        #expect(ICMPPinger.checksum([0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7][...]) == ~UInt16(0xddf2))
        #expect(ICMPPinger.checksum([0xff][...]) == ~UInt16(0xff00))
    }

    @Test func echoRequestIsWellFormed() {
        let p = ICMPPinger.echoRequest(identifier: 0x1234, sequence: 7, payload: payload)
        #expect(p.count == 8 + 16)
        #expect(Array(p[0..<2]) == [8, 0])
        #expect(Array(p[4..<8]) == [0x12, 0x34, 0, 7])
        #expect(ICMPPinger.checksum(p[...]) == 0)
    }

    @Test func parsesEchoReplyWithTTL() {
        let parsed = ICMPPinger.parseEchoReply(ipv4(reply(id: 0x1234, seq: 7, payload: payload), ttl: 115))
        #expect(parsed == .init(identifier: 0x1234, sequence: 7, ttl: 115, payload: payload))
        #expect(Latency.inferredHops(ttl: 115) == 13)
    }

    @Test func rejectsAnythingElse() {
        let good = reply(id: 1, seq: 2, payload: payload)
        var corrupt = good; corrupt[10] ^= 0xff
        let request = ICMPPinger.echoRequest(identifier: 1, sequence: 2, payload: payload)
        var unreachable = good; unreachable[0] = 3
        #expect(ICMPPinger.parseEchoReply(ipv4(corrupt)) == nil)
        #expect(ICMPPinger.parseEchoReply(ipv4(request)) == nil)
        #expect(ICMPPinger.parseEchoReply(ipv4(unreachable)) == nil)
        #expect(ICMPPinger.parseEchoReply(ipv4(good, proto: 17)) == nil)
        #expect(ICMPPinger.parseEchoReply(Array(ipv4(good).prefix(25))) == nil)
        #expect(ICMPPinger.parseEchoReply([]) == nil)
        var v6 = ipv4(good); v6[0] = 0x65
        #expect(ICMPPinger.parseEchoReply(v6) == nil)
    }

    @Test func resolvesTargets() {
        #expect(resolveIPv4("1.1.1.1").map { String(cString: inet_ntoa($0)) } == "1.1.1.1")
        #expect(resolveIPv4("localhost") != nil)
        #expect(resolveIPv4("nonexistent.invalid") == nil)
        #expect(resolveIPv4("::1") == nil)
    }
}

@Suite(.serialized) struct ICMPPingerTests {
    @Test func loopbackReplies() {
        let r = Latency.ping("127.0.0.1", timeoutMs: 1000)
        guard case .reply(let echo) = r else { Issue.record("expected a reply, got \(r)"); return }
        #expect(echo.hops == 0)
        #expect(echo.ms < 50)
    }

    @Test func concurrentProbesEachGetTheirOwnReply() {
        let results = NSLock()
        var replies = 0
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if case .reply = ICMPPinger.shared.ping(resolveIPv4("127.0.0.1")!, timeoutMs: 2000) {
                results.lock(); replies += 1; results.unlock()
            }
        }
        #expect(replies == 64)
    }

    @Test func unansweredProbeIsLostWithinTimeout() {
        // TEST-NET-1 (RFC 5737) is never routed: either no reply or no route, both loss.
        let t0 = Date()
        let r = ICMPPinger.shared.ping(resolveIPv4("192.0.2.1")!, timeoutMs: 300)
        #expect(r == .lost)
        #expect(Date().timeIntervalSince(t0) < 2)
    }

    @Test func unresolvableTargetIsUnmeasuredNotLost() {
        guard case .unmeasured = Latency.ping("nonexistent.invalid", timeoutMs: 300) else {
            Issue.record("expected unmeasured"); return
        }
    }

    @Test func subprocessFallbackStillWorks() {
        guard case .reply(let echo) = Latency.subprocessPing("127.0.0.1", timeoutMs: 1000) else {
            Issue.record("expected a reply"); return
        }
        #expect(echo.hops == 0)
    }

    @Test func probesLaunchNoProcesses() {
        let before = HelperPIDs.shared.count
        for _ in 0..<5 { _ = Latency.ping("127.0.0.1", timeoutMs: 1000) }
        #expect(HelperPIDs.shared.count == before)
    }
}
