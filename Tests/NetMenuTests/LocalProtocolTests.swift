import Darwin
import Foundation
import Testing
@testable import NetMenu

@Suite struct LocalProtocolTests {
    let router = LocalRouter(interface: "lo0", address: "127.0.0.1")
    private func reply(_ ms: Double = 5) -> Latency.PingOutcome { .reply(.init(ms: ms, hops: nil)) }

    @Test func discoversDNSAndDoesNotHideIsolatedLoss() {
        let session = LocalProbeSession()
        var calls: [LocalProbeMethod] = []
        let first = session.measure(router, now: 0) { method, _ in
            calls.append(method)
            return method == .dns ? reply() : .lost
        }
        #expect(first.method == .dns)
        #expect(calls == [.icmp, .dns])
        calls = []
        let missed = session.measure(router, now: 3) { method, _ in calls.append(method); return .lost }
        #expect(calls == [.dns])
        #expect(missed.method == .dns)
        guard case .lost = missed.outcome else { Issue.record("A missed reply must count as loss"); return }
    }

    @Test func discoveryIsThrottledAndChangesOnlyAfterRepeatedFailure() {
        let session = LocalProbeSession()
        _ = session.measure(router, now: 0) { _, _ in reply() }
        for time in [3.0, 6] {
            var calls: [LocalProbeMethod] = []
            _ = session.measure(router, now: time) { method, _ in calls.append(method); return .lost }
            #expect(calls == [.icmp])
        }
        let changed = session.measure(router, now: 9) { method, _ in method == .tcp443 ? reply() : .lost }
        #expect(changed.method == .tcp443)
        for time in [12.0, 15, 18, 21] {
            var calls: [LocalProbeMethod] = []
            _ = session.measure(router, now: time) { method, _ in calls.append(method); return .lost }
            #expect(calls == [.tcp443])
        }
        #expect(session.measure(router, epoch: 1, now: 22) { _, _ in reply() }.method == .icmp)
    }

    @Test func unsupportedProtocolsDoNotInventSuccessAndDHCPIsAvailableAsLastFallback() {
        let session = LocalProbeSession()
        let first = session.measure(router, now: 0) { _, _ in .unmeasured("unavailable") }
        guard case .unmeasured = first.outcome else { Issue.record("No protocol answered"); return }
        var calls: [LocalProbeMethod] = []
        _ = session.measure(router, now: 3) { method, _ in calls.append(method); return .lost }
        #expect(calls == [.icmp])
        let result = session.measure(router, now: 30) { method, _ in method == .dhcp ? reply() : .lost }
        #expect(result.method == .dhcp)
    }

    @Test func protocolSwitchStartsNewWindowWithoutFakeJitterOrLoss() {
        var tracker = LocalHealthTracker()
        for i in 0..<3 { tracker.record(reply(3), at: Double(i)) }
        #expect(tracker.report(now: 2)?.score == 100)
        tracker.record(reply(100), method: .dns, at: 3)
        #expect(tracker.report(now: 3) == nil)
        tracker.record(reply(100), method: .dns, at: 4)
        tracker.record(reply(100), method: .dns, at: 5)
        #expect(tracker.report(now: 5)?.jitterMs == 0)
        #expect(tracker.report(now: 5)?.loss == 0)
        #expect(tracker.menuTitle(router: "127.0.0.1", report: tracker.report(now: 5)).contains("DNS"))
    }

    @Test func dnsDoesNotRecurseAndRejectsUnrelatedOrMalformedReplies() {
        let query = DNSProbe.request(id: 1234)
        #expect(query[2] & 1 == 0)
        var response = query; response[2] = 0x80; response[3] = 5 // REFUSED still proves reachability
        #expect(DNSProbe.matches(response, request: query))
        #expect(!DNSProbe.matches(query, request: query))
        var other = response; other[0] ^= 1
        #expect(!DNSProbe.matches(other, request: query))
        other = response; other[14] = 1
        #expect(!DNSProbe.matches(other, request: query))
        for i in 0..<response.count { #expect(!DNSProbe.matches(Array(response.prefix(i)), request: query)) }
    }

    @Test func dhcpOnlyInformsAndRequiresMatchingDirectACK() {
        let client = DHCPProbe.Client(ip: [192, 168, 1, 20], mac: [0, 1, 2, 3, 4, 5])
        let request = DHCPProbe.request(client: client, xid: 0x12345678)
        #expect(Array(request[4..<8]) == [0x12, 0x34, 0x56, 0x78])
        #expect(Array(request[12..<16]) == client.ip)
        #expect(Array(request[240..<248]) == [53, 1, 8, 55, 2, 1, 3, 255])
        var ack = Array(request.prefix(240)); ack[0] = 2
        ack += [53, 1, 5, 54, 4, 192, 168, 1, 1, 255]
        #expect(DHCPProbe.matches(ack, request: request, server: "192.168.1.1"))
        for i in 0..<ack.count { #expect(!DHCPProbe.matches(Array(ack.prefix(i)), request: request, server: "192.168.1.1")) }
        for offset in [0, 4, 28, 236, 242, 246] {
            var bad = ack; bad[offset] ^= 1
            #expect(!DHCPProbe.matches(bad, request: request, server: "192.168.1.1"))
        }
        var relay = ack; relay[24] = 10
        #expect(!DHCPProbe.matches(relay, request: request, server: "192.168.1.1"))
        #expect(!DHCPProbe.matches(ack, request: request, server: "192.168.1.2"))
    }

    // Use ephemeral loopback ports so tests never contact a real DNS/DHCP service.
    private func boundSocket(_ type: Int32) throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, type, 0)
        #expect(fd >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(status == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    @Test func tcpAcceptAndRefusalBothProveReachability() throws {
        let (closed, unusedPort) = try boundSocket(SOCK_STREAM)
        close(closed)
        guard case .reply = LocalProtocols.tcp(router, port: unusedPort) else { Issue.record("Refusal should prove reachability"); return }
        let (fd, port) = try boundSocket(SOCK_STREAM)
        defer { close(fd) }
        #expect(listen(fd, 1) == 0)
        guard case .reply = LocalProtocols.tcp(router, port: port) else { Issue.record("Handshake should prove reachability"); return }
    }

    @Test func dnsRoundTripIgnoresWrongTransactionBeforeAcceptingResponse() throws {
        let (fd, port) = try boundSocket(SOCK_DGRAM)
        defer { close(fd) }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 2000) > 0 else { return }
            var bytes = [UInt8](repeating: 0, count: 512), peer = sockaddr_storage()
            var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &bytes, bytes.count, 0, $0, &size) }
            }
            guard n == 17 else { return }
            var response = Array(bytes.prefix(n)); response[2] = 0x80
            var wrong = response; wrong[0] ^= 1
            withUnsafePointer(to: &peer) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, wrong, wrong.count, 0, $0, size)
                    _ = sendto(fd, response, response.count, 0, $0, size)
                }
            }
        }
        let query = DNSProbe.request(id: 789)
        let result = LocalProtocols.exchange(router, port: port, request: query) { DNSProbe.matches($0, request: query) }
        #expect(done.wait(timeout: .now() + 3) == .success)
        guard case .reply(let echo) = result else { Issue.record("Matching DNS response should answer"); return }
        #expect(echo.ms >= 0 && echo.ms < 1000)
    }

    @Test func udpTimeoutIsBoundedAndUnavailableInterfaceIsNotLoss() throws {
        let (fd, port) = try boundSocket(SOCK_DGRAM)
        defer { close(fd) }
        let start = HealthTracker.now()
        let result = LocalProtocols.exchange(router, port: port, request: [1]) { _ in true }
        guard case .lost = result else { Issue.record("Unanswered datagram must time out"); return }
        #expect(HealthTracker.now() - start < 2)
        let missing = LocalRouter(interface: "nonexistent0", address: "127.0.0.1")
        guard case .unmeasured = LocalProtocols.tcp(missing, port: port) else { Issue.record("Missing interface is not network loss"); return }
    }
}
