import Foundation
import Testing
@testable import NetMenu

@Suite struct LiveMonitoringTests {
    @Test @MainActor func routerTransportReceivesContextAndDoesNotBlockWAN() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let target = LocalRouter(interface: "en0", address: "192.0.2.1")
        let transport = LiveProbes.Transport(ping: { _, _ in .reply(.init(ms: 20, hops: 12)) },
            website: { _, _ in .init(outcome: .ok, seconds: 0) }, portal: { .internet }, fallback: { _ in 30 },
            local: { router, epoch in
                #expect(router == target)
                #expect(epoch == 7)
                _ = gate.wait(timeout: .now() + 5)
                return .init(method: .dns, outcome: .reply(.init(ms: 4, hops: nil)))
            })
        let probes = LiveProbes(transport: transport)
        var wanReplies = 0
        var localReply: LocalProbeResult?
        probes.receive = { epoch, event in
            #expect(epoch == 7)
            if case .wan = event { wanReplies += 1 }
            if case .router(let result) = event { localReply = result }
        }
        let identity = Identity(iface: "en0", type: NetType.wifi, network: nil, bssid: nil,
            router: target.address, rssi: nil, noise: nil, txRate: nil, channel: nil, localRouter: target)
        probes.poll(identity: identity, epoch: 7, paused: false)
        for _ in 0..<100 {
            if wanReplies == 5 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(wanReplies == 5)
        #expect(localReply == nil)
        gate.signal()
        for _ in 0..<100 {
            if localReply != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(localReply?.method == .dns)
        if case .reply(let reply) = localReply?.outcome {
            #expect(reply.ms == 4)
        } else { Issue.record("Expected the injected router reply") }
    }

    @Test func partialRepliesDoNotManufactureCalibrationOrLoss() {
        var health = LiveHealthTracker()
        for slot in 0..<5 { health.recordTarget(slot: slot, verdict: .wan(20), started: 0, at: 0.1) }
        #expect(health.report(now: 1) == nil)
        health.recordTarget(slot: 0, verdict: .wan(20), started: 3, at: 3.1)
        health.recordTarget(slot: 0, verdict: .wan(20), started: 6, at: 6.1)
        #expect(health.report(now: 7)?.score == 100)
        #expect(health.report(now: 7)?.loss == 0)
        // A timeout completes the older round; it must not displace newer replies or add a round.
        health.recordTarget(slot: 1, verdict: .noReply, started: 3, at: 11)
        #expect((health.report(now: 11)?.loss ?? 0) > 0)
        #expect(health.latencyReadings(now: 11) == [20, 20, 20])
    }

    @Test func httpsFallbackDoesNotInheritLossFromFilteredICMP() {
        var health = LiveHealthTracker()
        for t in [0.0, 3, 6] { health.recordTarget(slot: 0, verdict: .wan(20), started: t, at: t) }
        for t in [10.0, 13, 16] {
            health.recordTarget(slot: 0, verdict: .noReply, started: t, at: t + 8)
            health.recordFallback(30, at: t + 8)
        }
        #expect(health.transportReport(now: 24)?.score == 100)
        #expect(health.transportReport(now: 24)?.loss == 0)
        #expect(health.transportReport(now: 24)?.latencyMs == 30)
        #expect(health.transportReport(now: 24)?.latencySources == [.http])
        let https = health.transportReport(now: 24)!
        health.recordTarget(slot: 0, verdict: .wan(20), started: 25, at: 25)
        #expect(health.transportReport(now: 25)?.latencyMs == 20)
        #expect(health.transportReport(now: 25)?.latencySources == [.icmp])
        #expect(HealthDisplay.mean([https, health.transportReport(now: 25)!]).latencySources == [.icmp, .http])
    }

    @Test func websiteFailureCountIsIndependentOfPingCompletions() {
        var health = LiveHealthTracker()
        for t in [0.0, 3, 6] { health.recordTarget(slot: 0, verdict: .wan(20), started: t, at: t) }
        health.recordWeb(["a": false, "b": false], at: 7)
        for slot in 1..<5 { health.recordTarget(slot: slot, verdict: .wan(20), started: 6, at: 8) }
        #expect(health.report(now: 8)?.internetReachable == true)
        #expect(health.report(now: 8)?.websitesFailing == true)
        health.recordWeb([:], at: 9) // Unmeasured is not another failure.
        #expect(health.report(now: 9)?.internetReachable == true)
        health.recordWeb(["a": false, "b": false], at: 10)
        #expect(health.report(now: 10)?.score == 0)
        #expect(health.report(now: 10)?.internetReachable == false)
        health.recordWeb(["a": true, "b": false], at: 11)
        #expect(health.report(now: 11)?.score == 100)
        #expect(health.report(now: 42)?.internetReachable == true)
    }

    @Test func corroboratedOutageBypassesCalibrationAndSmoothing() {
        var health = LiveHealthTracker(), display = HealthDisplay()
        health.recordWeb(["a": false], at: 1)
        health.recordPortal(true, at: 1)
        let report = health.report(now: 1)
        #expect(report?.score == 0)
        display.add(HealthReport(score: 100, loss: 0, jitterMs: 0, latencyMs: 20))
        _ = display.publish(now: 0)
        display.add(report)
        let outagePublished = display.publish(now: 1)
        #expect(outagePublished)
        #expect(display.shown?.score == 0)
    }

    @Test func settlingStillExcludesFailuresButRecentTroubleDoesNot() {
        var health = LiveHealthTracker(), recent = RecentTrouble()
        recent.record(.wan(20), target: "a", label: "network", at: 0)
        health.settle(at: 1)
        let settlingFailureExcluded = !health.recordTarget(slot: 0, verdict: .noReply, started: 2, at: 2)
        #expect(settlingFailureExcluded)
        recent.record(.noReply, target: "a", label: "network", at: 2)
        #expect(recent.labels(now: 2) == ["network loss"])
        #expect(recent.labels(now: 12).isEmpty)
        let successAccepted = health.recordTarget(slot: 0, verdict: .wan(20), started: 3, at: 3)
        #expect(successAccepted)
        let laterFailureAccepted = health.recordTarget(slot: 0, verdict: .noReply, started: 4, at: 4)
        #expect(laterFailureAccepted)
    }

    @Test func neverAnsweredAndUnmeasuredTargetsDoNotCauseRecentLoss() {
        var recent = RecentTrouble()
        recent.record(.noReply, target: "blocked", label: "network", at: 0)
        recent.record(.unmeasured, target: "unknown", label: "network", at: 0)
        #expect(recent.labels(now: 0).isEmpty)
        recent.record(.wan(20), target: "a", label: "network", at: 1)
        recent.record(.wan(400), target: "a", label: "network", at: 2)
        #expect(recent.labels(now: 2).contains("network latency"))
        #expect(recent.labels(now: 2).contains("network jitter"))
    }

    @Test func lowLatencyHasRoomForJitterWithoutWarning() {
        var recent = RecentTrouble()
        recent.record(.wan(20), target: "a", label: "network", at: 0)
        recent.record(.wan(70), target: "a", label: "network", at: 1)
        #expect(recent.labels(now: 1).isEmpty)
    }

    @Test func reconnectsExcludeStartupDuplicatesWakeAndExpiredEvents() {
        var history = ReconnectHistory()
        history.observe(connected: false, at: 0)
        history.observe(connected: true, at: 1)
        #expect(history.count(now: 1) == 0)
        history.observe(connected: false, at: 10)
        history.observe(connected: false, at: 11)
        history.observe(connected: true, at: 12)
        history.observe(connected: true, at: 13)
        #expect(history.count(now: 13) == 1)
        history.observe(connected: false, at: 20)
        history.observe(connected: true, at: 21)
        #expect(history.count(now: 21) == 2)
        #expect(history.count(now: 312) == 1)
        #expect(history.count(now: 321) == 0)
        history.wake()
        history.observe(connected: false, at: 322)
        history.observe(connected: true, at: 323)
        #expect(history.count(now: 323) == 0)
    }

    @Test func slowLanesAreBoundedAndFastRetriesRespectThreeSeconds() {
        var lane = ProbeLane()
        let initialStart = lane.start(at: 0, interval: 15)
        #expect(initialStart)
        lane.expedite()
        let inFlightBlocked = !lane.start(at: 3, interval: 3)
        #expect(inFlightBlocked)
        lane.finish()
        let earlyRetryBlocked = !lane.start(at: 2, interval: 3)
        #expect(earlyRetryBlocked)
        let retryStarted = lane.start(at: 3, interval: 3)
        #expect(retryStarted)
        lane.resetSchedule()
        let oldEpochStillBounded = !lane.start(at: 4, interval: 3)
        #expect(oldEpochStillBounded)
        lane.finish()
        let newEpochStarted = lane.start(at: 4, interval: 3)
        #expect(newEpochStarted)
    }

    @Test @MainActor func blockedWebAndOneWANDoNotBlockOtherWANRepliesAndOldEpochsAreDiscarded() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { for _ in 0..<10 { gate.signal() } }
        let slowHost = Latency.icmpTargets[0]
        let transport = LiveProbes.Transport(ping: { host, _ in
            if host == slowHost { _ = gate.wait(timeout: .now() + 5) }
            return .reply(.init(ms: 20, hops: 12))
        }, website: { _, _ in
            _ = gate.wait(timeout: .now() + 5)
            return .init(outcome: .ok, seconds: 0)
        }, portal: { .internet }, fallback: { _ in 30 })
        let probes = LiveProbes(transport: transport)
        var replies: [(Int, Int)] = []
        probes.receive = { epoch, event in
            if case .wan(_, let slot, _, _, _) = event { replies.append((epoch, slot)) }
        }
        let identity = Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil,
                                router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
        let now = HealthTracker.now()
        probes.poll(identity: identity, epoch: 1, paused: false, now: now)
        for _ in 0..<100 {
            if replies.count == 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(replies.count == 4)
        #expect(!replies.contains { $0.1 == 0 })
        probes.poll(identity: identity, epoch: 2, paused: true, now: now + 1)
        for _ in 0..<5 { gate.signal() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(replies.count == 4) // The old slow ping must not leak into the new network.
    }
}
