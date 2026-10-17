import Darwin
import Foundation
import Testing
@testable import NetMenu

@Suite struct IPConnectivityTests {
    private func checks(ipv4: Bool, ipv6: Bool) -> IPWebsiteChecks {
        let sites = Latency.InternetSite.allCases.map(\.rawValue)
        return IPWebsiteChecks(ipv4: Dictionary(uniqueKeysWithValues: sites.map { ($0, ipv4) }),
                               ipv6: Dictionary(uniqueKeysWithValues: sites.map { ($0, ipv6) }))
    }

    private func calibrated() -> LiveHealthTracker {
        var health = LiveHealthTracker()
        for at in [0.0, 3, 6] { health.recordFallback(20, at: at) }
        return health
    }

    @Test func ipv6AndFallbackCannotMaskConfirmedIPv4Failure() throws {
        var health = calibrated()
        let v6Only = checks(ipv4: false, ipv6: true)
        health.recordIPWeb(v6Only, at: 7)
        #expect(health.report(now: 7)?.score == 100)
        health.recordFallback(20, at: 8)
        // Other completions cannot count one website round twice.
        #expect(health.report(now: 8)?.ipv4Unavailable == false)
        health.recordIPWeb(v6Only, at: 10)
        let report = try #require(health.report(now: 10))
        #expect(report.score == 33)
        #expect(report.ipv4Unavailable)
        #expect(report.ipv6Reachable)
        #expect(report.internetReachable) // Partial connectivity remains accurately represented.
        #expect(health.transportReport(now: 10)?.score == 100)
    }

    @Test func ipv6OnlyScalesDegradedHealthAndNeverRoundsToZero() throws {
        var health = LiveHealthTracker()
        for at in [0.0, 3, 6] { health.recordFallback(620, at: at) }
        #expect(health.transportReport(now: 10)?.score == 50)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 7)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 10)
        #expect(health.report(now: 10)?.score == 17)
        #expect(health.report(now: 10)?.score == 17) // Reading twice never applies the divisor twice.

        health.reset()
        for at in [0.0, 3, 6] { health.recordFallback(nil, at: at) }
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 7)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 10)
        #expect(health.transportReport(now: 10)?.score == 0)
        #expect(health.report(now: 10)?.score == 1)
        var display = HealthDisplay()
        display.add(health.report(now: 10))
        _ = display.publish(now: 10)
        health.recordIPWeb(checks(ipv4: false, ipv6: false), at: 11)
        display.add(health.report(now: 11))
        let lostIPv6 = display.publish(now: 11)
        #expect(lostIPv6)
        #expect(display.shown?.score == 0)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 12)
        display.add(health.report(now: 12))
        let recoveredIPv6 = display.publish(now: 12)
        #expect(recoveredIPv6)
        #expect(display.shown?.score == 1)
    }

    @Test func ipv4AloneIsHealthyAndRecoversImmediately() throws {
        var health = calibrated(), display = HealthDisplay()
        display.add(health.report(now: 6))
        _ = display.publish(now: 6)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 7)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 8)
        display.add(health.report(now: 8))
        let outagePublished = display.publish(now: 8)
        #expect(outagePublished)
        #expect(display.shown?.score == 33)
        #expect(display.shown?.ipv4Unavailable == true)
        health.recordIPWeb(checks(ipv4: true, ipv6: false), at: 9)
        display.add(health.report(now: 9))
        let recoveryPublished = display.publish(now: 9)
        #expect(recoveryPublished)
        #expect(display.shown?.score == 100)
        #expect(display.shown?.ipv4Unavailable == false)
        #expect(display.shown?.ipv6Reachable == false)
        health.recordIPWeb(checks(ipv4: true, ipv6: false), at: 12)
        #expect(health.report(now: 12)?.score == 100)
        #expect(health.report(now: 12)?.websitesFailing == false)
    }

    @Test func calibrationAndFreshnessDoNotHideOrRetainCriticalFailure() {
        var health = LiveHealthTracker()
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 0)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 3)
        #expect(health.report(now: 3)?.score == 33)
        #expect(health.report(now: 31) == nil) // First failure expired; no longer confirmed.
        health.reset()
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 4)
        #expect(health.report(now: 4) == nil)
    }

    @Test func incompleteChecksAndSingleSiteFailuresDoNotConfirmAnOutage() {
        var health = calibrated()
        let failed = checks(ipv4: false, ipv6: true)
        health.recordIPWeb(failed, at: 7)
        var partial = failed
        partial.ipv4.removeValue(forKey: Latency.InternetSite.example.rawValue)
        #expect(partial.status(for: .ipv4) == .unknown)
        health.recordIPWeb(partial, at: 10)
        health.recordIPWeb(failed, at: 13)
        #expect(health.report(now: 13)?.score == 100)
        partial.ipv4[Latency.InternetSite.example.rawValue] = true
        #expect(partial.status(for: .ipv4) == .reachable)
        health.recordIPWeb(partial, at: 16)
        #expect(health.report(now: 16)?.score == 100)
    }

    @Test func settlingSuppressesFailuresUntilConnectivityReturns() {
        var health = LiveHealthTracker()
        health.settle(at: 0)
        health.recordIPWeb(checks(ipv4: false, ipv6: false), at: 1)
        health.recordIPWeb(checks(ipv4: false, ipv6: false), at: 2)
        #expect(health.report(now: 2) == nil)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 3)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 4)
        #expect(health.report(now: 4)?.ipv4Unavailable == true)
    }

    @Test @MainActor func schedulerChecksBothFamiliesAndRetriesIPv4Failure() async throws {
        let failing = Locked(true)
        let transport = LiveProbes.Transport(ping: { _, _ in .reply(.init(ms: 20, hops: 12)) },
            website: { _, family in
                .init(outcome: family == .ipv4 && failing.value ? .failed("no route") : .ok, seconds: 0)
            }, portal: { .internet }, fallback: { _ in 20 })
        let probes = LiveProbes(transport: transport)
        var rounds: [IPWebsiteChecks] = []
        probes.receive = { _, event in
            if case .websites(let checks) = event { rounds.append(checks) }
        }
        let identity = Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil,
                                router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
        let now = HealthTracker.now()
        probes.poll(identity: identity, epoch: 1, paused: false, now: now)
        for _ in 0..<100 {
            if rounds.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rounds.count == 1)
        #expect(rounds.first?.status(for: .ipv4) == .unreachable)
        #expect(rounds.first?.status(for: .ipv6) == .reachable)
        failing.set(false)
        probes.poll(identity: identity, epoch: 1, paused: false, now: now + 3)
        for _ in 0..<100 {
            if rounds.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rounds.count == 2) // IPv6 success must not switch to the healthy 15-second cadence.
        #expect(rounds.last?.status(for: .ipv4) == .reachable)
    }

    @Test func switchingWANFamilyExcludesIPv4LossAndLatencyButKeepsPenalty() throws {
        var health = LiveHealthTracker()
        for at in [0.0, 3, 6] {
            health.recordTarget(slot: 0, verdict: .wan(620), started: at, at: at)
            health.recordTarget(slot: 1, verdict: .noReply, started: at, at: at)
        }
        health.recordFallback(900, at: 6)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 7)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 10)
        health.selectWANFamily(.ipv6)
        #expect(health.latencyReadings(now: 10).isEmpty)
        #expect(health.transportReport(now: 10) == nil)
        #expect(health.report(now: 10)?.ipv4Unavailable == true)
        for at in [11.0, 14, 17] {
            health.recordTarget(slot: 0, verdict: .wan(20), started: at, at: at)
            health.recordTarget(slot: 3, verdict: .wan(30), started: at, at: at)
        }
        let report = try #require(health.report(now: 17))
        #expect(report.score == 33)
        #expect(report.loss == 0)
        #expect(report.jitterMs == 0)
        #expect(report.latencyMs == 20)
        #expect(report.latencySources == [.icmp])
        #expect(health.latencyReadings(now: 17) == [20, 20, 20])
        health.selectWANFamily(.ipv4)
        health.recordIPWeb(checks(ipv4: true, ipv6: true), at: 18)
        for at in [19.0, 22, 25] { health.recordTarget(slot: 0, verdict: .wan(40), started: at, at: at) }
        #expect(health.report(now: 25)?.score == 100)
        #expect(health.latencyReadings(now: 25) == [40, 40, 40])
    }

    @Test @MainActor func IPv6StartsWhileIPv4IsBlockedAndOldRepliesCannotSurviveSwitchingBack() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { for _ in Latency.icmpTargets { gate.signal() } }
        let recovered = Locked(false), blocked = Locked(0), finished = Locked(0)
        let transport = LiveProbes.Transport(ping: { host, _ in
            if !host.contains(":"), !recovered.value {
                blocked.mutate { $0 += 1 }
                _ = gate.wait(timeout: .now() + 5)
                finished.mutate { $0 += 1 }
                return .reply(.init(ms: 999, hops: 12))
            }
            return .reply(.init(ms: host.contains(":") ? 20 : 40, hops: 12))
        }, website: { _, family in
            .init(outcome: family == .ipv4 && !recovered.value ? .failed("no route") : .ok, seconds: 0)
        }, portal: { .internet }, fallback: { _ in nil })
        let probes = LiveProbes(transport: transport)
        var families: [IPVersion] = [], replies: [(IPVersion, Double)] = []
        probes.receive = { _, event in
            if case .wanFamily(let family) = event { families.append(family) }
            if case .wan(let family, _, _, .reply(let reply), _) = event { replies.append((family, reply.ms)) }
        }
        let identity = Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil,
                                router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
        let now = HealthTracker.now()
        probes.poll(identity: identity, epoch: 1, paused: false, now: now)
        for _ in 0..<100 {
            if families == [.ipv6] && blocked.value == Latency.icmpTargets.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(families == [.ipv6])
        #expect(blocked.value == Latency.icmpTargets.count)
        probes.poll(identity: identity, epoch: 1, paused: false, now: now + 1)
        for _ in 0..<100 {
            if replies.count == Latency.icmp6Targets.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(replies.count == Latency.icmp6Targets.count)
        #expect(replies.allSatisfy { $0.0 == .ipv6 && $0.1 == 20 })
        recovered.set(true)
        probes.poll(identity: identity, epoch: 1, paused: false, now: now + 3)
        for _ in 0..<100 {
            if families == [.ipv6, .ipv4] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(families == [.ipv6, .ipv4])
        for _ in Latency.icmpTargets { gate.signal() }
        for _ in 0..<100 {
            if finished.value == Latency.icmpTargets.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!replies.contains { $0.1 == 999 })
        probes.poll(identity: identity, epoch: 1, paused: false, now: now + 4)
        for _ in 0..<100 {
            if replies.contains(where: { $0.0 == .ipv4 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(replies.contains { $0.0 == .ipv4 && $0.1 == 40 })
        #expect(!replies.contains { $0.1 == 999 })
    }

    @Test @MainActor func ipv6HTTPSFallbackDoesNotWaitForOldIPv4Fallback() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let v6Ready = Locked(false), calls = Locked<[IPVersion]>([])
        let transport = LiveProbes.Transport(ping: { _, _ in .lost }, website: { _, family in
            .init(outcome: family == .ipv6 && v6Ready.value ? .ok : .failed("no route"), seconds: 0)
        }, portal: { .unknown }, fallback: { family in
            calls.mutate { $0.append(family) }
            if family == .ipv4 { _ = gate.wait(timeout: .now() + 5) }
            return family == .ipv6 ? 25 : 999
        })
        let probes = LiveProbes(transport: transport)
        var selected = IPVersion.ipv4
        var results: [(IPVersion, Double?)] = []
        probes.receive = { _, event in
            if case .wanFamily(let family) = event { selected = family }
            if case .fallback(let family, let ms) = event { results.append((family, ms)) }
        }
        let identity = Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil,
                                router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
        let now = HealthTracker.now()
        probes.poll(identity: identity, epoch: 1, paused: false, now: now)
        try await Task.sleep(for: .milliseconds(50))
        v6Ready.set(true)
        probes.poll(identity: identity, epoch: 1, paused: false, now: now + 9)
        for _ in 0..<100 {
            if selected == .ipv6 && calls.value.contains(.ipv4) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(selected == .ipv6)
        #expect(calls.value.contains(.ipv4))
        probes.poll(identity: identity, epoch: 1, paused: false, now: now + 18)
        for _ in 0..<100 {
            if !results.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls.value.contains(.ipv6))
        #expect(results.count == 1)
        #expect(results.first?.0 == .ipv6)
        #expect(results.first?.1 == 25)
    }

    @Test func IPv6HopLimitRejectsMissingTruncatedAndLocalReplies() {
        var header = cmsghdr()
        header.cmsg_len = socklen_t(MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size)
        header.cmsg_level = IPPROTO_IPV6
        header.cmsg_type = IPv6Pinger.hopLimitControlType
        var hopLimit: Int32 = 52
        var control = withUnsafeBytes(of: &header) { Array($0) }
        control += withUnsafeBytes(of: &hopLimit) { Array($0) }
        let ttl = IPv6Pinger.hopLimit(control: control, length: control.count)
        #expect(ttl == 52)
        #expect(Latency.judge(.init(ms: 20, hops: ttl.map(Latency.inferredHops)), gatewayMs: nil) == .wan(20))
        #expect(IPv6Pinger.hopLimit(control: control, length: control.count - 1) == nil)
        #expect(IPv6Pinger.hopLimit(control: [], length: 0) == nil)
        #expect(Latency.judge(.init(ms: 20, hops: nil), gatewayMs: nil) == .noReply)
        #expect(Latency.judge(.init(ms: 20, hops: Latency.inferredHops(ttl: 63)), gatewayMs: nil) == .onPath)
    }

    @Test func IPv6LoopbackProvidesReceivedHopLimit() {
        let result = IPv6Pinger.ping("::1", timeoutMs: 1000)
        guard case .reply(let reply) = result else { Issue.record("Expected IPv6 loopback reply: \(result)"); return }
        #expect(reply.hops == 0)
        #expect(reply.ms < 100)
    }

    @Test @MainActor func menuExplainsPartialConnectivityAndClearsOnRecovery() {
        let app = AppDelegate()
        var report = HealthReport(score: 33, loss: 0, jitterMs: nil, latencyMs: nil,
                                  ipv4Unavailable: true, ipv6Reachable: true)
        let warning = app.healthMenuReadout(report)
        #expect(warning.score == 33)
        #expect(warning.detail == "⚠ IPv4 unavailable; IPv6 is working")
        #expect(warning.title.contains("IPv4 unavailable"))
        report.ipv6Reachable = false
        report.score = 0
        #expect(app.healthMenuReadout(report).detail == "⚠ IPv4 internet unavailable")
        report.ipv4Unavailable = false
        report.score = 100
        #expect(!app.healthMenuReadout(report).detail.contains("⚠"))
    }
}
