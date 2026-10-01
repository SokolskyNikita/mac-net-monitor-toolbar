import Foundation
import Testing
@testable import NetMenu

private typealias V = Latency.EchoVerdict

/// One probe cycle. By default all five targets answered with `ms`, or all were lost when `ms` is nil.
private func cycle(_ ms: Double?, source: LatencySource = .icmp, targets: [V]? = nil, at: Double = 0,
                   internetReachable: Bool = true, corroborated: Bool = false) -> HealthSample {
    let t = targets ?? Array(repeating: ms.map { .wan($0) } ?? .noReply, count: 5)
    return HealthSample(at: at, ms: ms, source: ms == nil ? nil : source, targets: t,
                        internetReachable: internetReachable, corroborated: corroborated)
}

/// 20 cycles of 5 targets at `ms`, with `lost` of the 100 echoes lost, spread evenly across targets.
private func spreadLoss(_ lost: Int, ms: Double = 20) -> [HealthSample] {
    (0..<20).map { i in
        cycle(ms, targets: (0..<5).map { t in i * 5 + t < lost ? .noReply : .wan(ms) })
    }
}

private func score(_ samples: [HealthSample]) -> Int {
    Health.evaluate(samples)?.score ?? -1
}

@Suite struct HealthCurveTests {
    let curve = HealthCurve(half: 30, steepness: 2, max: 0.8)

    @Test func halfPointIsHalfOfMax() {
        #expect(abs(curve.penalty(30) - 0.4) < 1e-9)
    }

    @Test func zeroNegativeAndNaNCostNothing() {
        #expect(curve.penalty(0) == 0)
        #expect(curve.penalty(-5) == 0)
        #expect(curve.penalty(.nan) == 0)
    }

    @Test func saturatesAtMax() {
        #expect(curve.penalty(.infinity) == 0.8)
        #expect(curve.penalty(100_000) < 0.8)
        #expect(curve.penalty(100_000) > 0.79)
    }

    @Test func fullPointReachesMaxExactly() {
        #expect(Health.lossCurve.penalty(1) == 1)
        #expect(Health.lossCurve.penalty(0.99) < 1)
        #expect(abs(Health.lossCurve.penalty(0.07) - 0.5) < 0.01)
    }

    @Test func freeZoneCostsNothingAndHalfIsMeasuredPastIt() {
        let c = HealthCurve(free: 40, half: 25, steepness: 2, max: 0.8)
        #expect(c.penalty(40) == 0)
        #expect(c.penalty(40.001) > 0)
        #expect(abs(c.penalty(65) - 0.4) < 1e-9)
    }

    @Test func isMonotonic() {
        let xs = stride(from: 0.0, through: 500, by: 5).map(curve.penalty)
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 })
    }
}

@Suite struct HealthScoreTests {
    @Test(arguments: [600.0, 650.0, 700.0])
    func modestSatelliteJitterHasNoExtraPenalty(baseline: Double) {
        let steady = (0..<20).map { _ in cycle(baseline) }
        let varying = (0..<20).map { cycle(baseline + ($0 % 2 == 0 ? -50 : 50)) }
        let report = try! #require(Health.evaluate(varying))
        #expect(report.jitterMs == 100)
        #expect(report.latencyMs == baseline)
        #expect(report.score == score(steady))
        #expect(report.score >= 50 && report.score <= 56)
    }

    @Test func largeRelativeSatelliteJitterStillHurts() {
        let steady = (0..<20).map { _ in cycle(650) }
        let moderate = (0..<20).map { cycle($0 % 2 == 0 ? 550 : 750) }
        let severe = (0..<20).map { cycle($0 % 2 == 0 ? 450 : 850) }
        #expect(score(moderate) < score(steady) - 15)
        #expect(score(severe) < score(moderate) - 15)
    }

    @Test func satelliteJitterAllowanceDoesNotMaskBlockedInternet() {
        let samples = (0..<20).map {
            cycle($0 % 2 == 0 ? 600 : 700, internetReachable: false)
        }
        #expect(score(samples) == 0)
    }

    @Test func restrictedInternetIsZeroEvenWithPerfectPing() {
        let samples = (0..<20).map { _ in cycle(15, internetReachable: false) }
        let r = Health.evaluate(samples)
        #expect(r?.score == 0)
        #expect(r?.loss == 0)
        #expect(r?.latencyMs == 15)
        #expect(r?.internetReachable == false)
    }

    @Test func oneFailedWebsiteCycleOnAWorkingLinkIsNotAnOutage() {
        let good = (0..<20).map { _ in cycle(15) }
        let r = try! #require(Health.evaluate(good + [cycle(15, internetReachable: false)]))
        #expect(r.score == 100)
        #expect(r.internetReachable)
        #expect(r.websitesFailing)
        #expect(Health.evaluate([cycle(15, internetReachable: false)]) == nil)
    }

    @Test func secondFailedWebsiteCycleConfirmsOutage() {
        let failure = cycle(657, internetReachable: false)
        #expect(score([failure, failure]) == 0)
        #expect(score((0..<20).map { _ in cycle(15) } + [failure, failure]) == 0)
    }

    @Test func corroboratedWebsiteFailureBypassesCalibrationAndHealthyHistory() {
        let dead = cycle(nil, internetReachable: false, corroborated: true)
        #expect(score([dead]) == 0)
        #expect(score((0..<20).map { _ in cycle(15) } + [dead]) == 0)
    }

    @Test func cyclesWithoutWebsiteVerdictDoNotBreakConfirmation() {
        var unknown = cycle(15); unknown.internet = .unknown
        let fail = cycle(15, internetReachable: false)
        let good = (0..<5).map { _ in cycle(15) }
        #expect(score(good + [fail, unknown, fail]) == 0)
        #expect(score(good + [fail, unknown]) == 100)
        #expect(score(good + [fail, cycle(15), fail]) == 100)
    }

    @Test func verifiedRecoveryRestoresNormalScoring() {
        #expect(score([cycle(15, internetReachable: false), cycle(15), cycle(15)]) == 100)
    }

    @Test func needsMinimumCycles() {
        #expect(Health.evaluate((1..<Health.minCycles).map { _ in cycle(15) }) == nil)
        #expect(Health.evaluate((0..<Health.minCycles).map { _ in cycle(15) }) != nil)
    }

    @Test func stableFastLinkIsPerfect() {
        let r = Health.evaluate([15, 16, 15, 14, 15, 16, 15, 15, 14, 15].map { cycle($0) })
        #expect(r?.loss == 0)
        #expect(r?.score == 100)
    }

    @Test func homeWifiWithOccasionalSpikesIsPerfect() {
        // `ping google.com` on a home connection, 2026-09-24: two spikes, otherwise ~16ms.
        let trace = [16.4, 16.5, 17.5, 15.9, 33.5, 79.8, 16.2, 15.9, 19.0, 16.5]
        #expect(score(trace.map { cycle($0) }) == 100)
    }

    @Test func linkAtZoomLimitsIsPerfect() {
        // Zoom: latency ≤150ms, jitter ≤40ms, loss ≤2%.
        let samples = (0..<20).map { i in
            let ms: Double = i % 2 == 0 ? 125 : 160
            return cycle(ms, targets: [i < 2 ? .noReply : .wan(ms), .wan(ms), .wan(ms), .wan(ms), .wan(ms)])
        }
        let r = try! #require(Health.evaluate(samples))
        #expect(abs(r.loss - 0.02) < 1e-9)
        #expect(r.jitterMs == 35)
        #expect(r.score == 100)
    }

    @Test func oscillatingLatencyIsBad() {
        let flapping = (0..<20).map { cycle($0 % 2 == 0 ? 15 : 100) }
        let r = try! #require(Health.evaluate(flapping))
        #expect(r.jitterMs == 85)
        #expect(r.score < 45)
    }

    @Test func oscillationIsWorseThanSteadyLinkWithSameMedian() {
        let flapping = (0..<20).map { cycle($0 % 2 == 0 ? 15 : 100) }
        let steady = (0..<20).map { _ in cycle(57.5) }
        #expect(score(steady) == 100)
        #expect(score(flapping) + 50 < score(steady))
    }

    @Test func singleSpikeIsTrimmed() {
        var samples = (0..<20).map { _ in cycle(15) }
        samples[10] = cycle(900)
        #expect(Health.evaluate(samples)?.jitterMs == 0)
        #expect(score(samples) == 100)
    }

    @Test func slowDriftIsNotJitter() {
        let ramp = (0..<20).map { cycle(20 + Double($0) * 2) }
        let r = try! #require(Health.evaluate(ramp))
        #expect(r.jitterMs == 2)
        #expect(r.score == 100)
    }

    @Test func highStableLatencyIsSlowNotBroken() {
        let satellite = (0..<20).map { _ in cycle(600) }
        let s = score(satellite)
        #expect(s >= 45 && s <= 65)
    }

    @Test func lossPastZoomLimitScoresLower() {
        func withLoss(_ lostEchoes: Int) -> Int { score(spreadLoss(lostEchoes)) }
        #expect(withLoss(0) == 100)
        #expect(withLoss(2) == 100)
        let scores = [2, 3, 5, 10, 15].map(withLoss)
        #expect(zip(scores, scores.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test func sevenPercentLossRoughlyHalvesScore() {
        // 7 of 100 echoes lost across all hosts: 5 points past Zoom's 2% limit.
        let r = try! #require(Health.evaluate(spreadLoss(7)))
        #expect(abs(r.loss - 0.07) < 1e-9)
        #expect(r.score >= 45 && r.score <= 52)
    }

    @Test func targetThatNeverAnswersIsNotLoss() {
        // Quad9 blocked on this network: every cycle, one target silent.
        let samples = (0..<10).map { _ in cycle(20, targets: [.wan(20), .wan(22), .wan(25), .noReply, .wan(30)]) }
        #expect(Health.evaluate(samples)?.loss == 0)
    }

    @Test func oneHostRateLimitingIcmpIsNotLinkLoss() {
        // 9.9.9.9 drops 30% of echoes; the other four answer every one.
        let samples = (0..<20).map { i in
            cycle(20, targets: [.wan(20), .wan(21), .wan(22), i % 10 < 3 ? .noReply : .wan(25), .wan(30)])
        }
        #expect(Health.evaluate(samples)?.loss == 0)
        #expect(score(samples) == 100)
    }

    @Test func lossOnEveryHostCountsInFull() {
        let r = try! #require(Health.evaluate(spreadLoss(10)))
        #expect(abs(r.loss - 0.10) < 1e-9)
        // Even when one host is lossier than the rest, shared loss is never discarded.
        let mixed = (0..<20).map { i in
            cycle(20, targets: [i < 2 ? .noReply : .wan(20), i < 2 ? .noReply : .wan(20), i < 2 ? .noReply : .wan(20),
                                i < 2 ? .noReply : .wan(20), i < 8 ? .noReply : .wan(20)])
        }
        let m = try! #require(Health.evaluate(mixed))
        #expect(abs(m.loss - 0.10) < 1e-9)
    }

    @Test func evenLossIsNotDiscardedOverFewCycles() {
        // Right after calibration, 10% loss on every host: chance alone makes one host look worse.
        let samples = [
            cycle(20, targets: [.noReply, .wan(20), .wan(20), .wan(20), .noReply]),
            cycle(20, targets: [.wan(20), .wan(20), .noReply, .wan(20), .noReply]),
            cycle(20, targets: [.wan(20), .wan(20), .wan(20), .wan(20), .wan(20)]),
        ]
        let r = try! #require(Health.evaluate(samples))
        #expect(abs(r.loss - 4.0 / 15) < 1e-9)
    }

    @Test func binomialTail() {
        #expect(abs(Health.binomialUpperTail(k: 1, n: 20, p: 0.05) - (1 - pow(0.95, 20))) < 1e-9)
        #expect(Health.binomialUpperTail(k: 0, n: 5, p: 0.1) == 1)
        #expect(Health.binomialUpperTail(k: 6, n: 20, p: 1.0 / 82) < 0.001)
    }

    @Test func unmeasuredProbesAreNotLoss() {
        // Today's bug: helpers failing to launch read as 30% loss on a perfect link.
        let samples = (0..<20).map { i in
            cycle(9, targets: (0..<5).map { t in (i + t) % 3 == 0 ? .unmeasured : .wan(9) })
        }
        let r = try! #require(Health.evaluate(samples))
        #expect(r.loss == 0)
        #expect(r.score == 100)
    }

    @Test func fastestHostChangingIsNotJitter() {
        // 1.1.1.1 at 10ms sometimes drops an echo; the published RTT falls back to 8.8.8.8 at 30ms.
        let samples = (0..<20).map { i in
            i % 4 == 0 ? cycle(30, targets: [.noReply, .wan(30)]) : cycle(10, targets: [.wan(10), .wan(30)])
        }
        #expect(Health.evaluate(samples)?.jitterMs == 0)
    }

    @Test func onPathEchoesAreIgnored() {
        let samples = (0..<10).map { _ in cycle(20, targets: [.onPath, .wan(20), .wan(22), .onPath, .wan(30)]) }
        #expect(Health.evaluate(samples)?.loss == 0)
    }

    @Test func blockedIcmpFallsBackToCycleLoss() {
        let blocked: [V] = Array(repeating: .noReply, count: 5)
        var samples = (0..<10).map { _ in cycle(80, source: .http, targets: blocked) }
        samples[3] = cycle(nil, targets: blocked)
        samples[7] = cycle(nil, targets: blocked)
        #expect(abs((Health.evaluate(samples)?.loss ?? 0) - 0.2) < 1e-9)
    }

    @Test func totalOutageIsZero() {
        let r = Health.evaluate((0..<5).map { _ in cycle(nil) })
        #expect(r?.score == 0)
        #expect(r?.loss == 1)
        #expect(r?.latencyMs == nil)
        #expect(r?.jitterMs == nil)
    }

    @Test func sourceSwitchIsNotJitter() {
        let samples = [cycle(20), cycle(20), cycle(20), cycle(300, source: .http), cycle(300, source: .http)]
        let r = try! #require(Health.evaluate(samples))
        #expect(r.jitterMs == 0)
        #expect(r.latencyMs == 300)
    }

    @Test func scoreStaysInRange() {
        let awful = (0..<20).map { i in
            i % 2 == 0 ? cycle(50) : cycle(5000, targets: [.noReply, .noReply, .noReply, .wan(5000), .wan(6000)])
        }
        let s = score(awful)
        #expect(s >= 0 && s <= 5)
    }
}

@Suite struct RelativeJitterTests {
    @Test(arguments: [0.0, 50.0, 150.0, 200.0])
    func fastLinksKeepExistingPenalties(latency: Double) {
        for jitter in [0.0, 40, 60, 85, 100, 400] {
            #expect(Health.jitterPenalty(jitter, latencyMs: latency) == Health.jitterCurve.penalty(jitter))
        }
    }

    @Test func sameRelativeVariationHasSamePenaltyOnSlowLinks() {
        let expected = Health.jitterPenalty(200, latencyMs: 650)
        #expect(expected > 0.3 && expected < 0.4)
        #expect(abs(Health.jitterPenalty(400, latencyMs: 1300) - expected) < 1e-9)
    }

    @Test func penaltyGrowsWithJitterAndFallsWithBaseline() {
        let byJitter = stride(from: 0.0, through: 1000, by: 10).map {
            Health.jitterPenalty($0, latencyMs: 650)
        }
        #expect(zip(byJitter, byJitter.dropFirst()).allSatisfy { $0 <= $1 })
        let byLatency = stride(from: 0.0, through: 1000, by: 10).map {
            Health.jitterPenalty(100, latencyMs: $0)
        }
        #expect(zip(byLatency, byLatency.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test func unavailableOrInvalidBaselineKeepsAbsolutePenalty() {
        for baseline: Double? in [nil, -1, .nan, .infinity] {
            #expect(Health.jitterPenalty(100, latencyMs: baseline) == Health.jitterCurve.penalty(100))
        }
    }
}

@Suite struct HealthTrackerTests {
    @Test func websiteFailureFlowsThroughTrackerToDisplayImmediately() {
        var tracker = HealthTracker()
        var display = HealthDisplay()
        for i in 0..<3 { tracker.record(probe(15), at: t0 + Double(i)) }
        display.add(tracker.report(now: t0 + 2))
        _ = display.publish(now: t0 + 2)
        #expect(display.shown?.score == 100)

        var restricted = probe(15)
        restricted.internetChecks = ["example.com": false, "www.google.com": false]
        tracker.record(restricted, at: t0 + 3)
        display.add(tracker.report(now: t0 + 3))
        _ = display.publish(now: t0 + 3)
        #expect(display.shown?.score == 100)
        tracker.record(restricted, at: t0 + 6)
        display.add(tracker.report(now: t0 + 6))
        _ = display.publish(now: t0 + 6)
        #expect(display.shown?.score == 0)
        #expect(display.shown?.latencyMs == 15)
    }

    @Test func cycleThatMeasuredNothingIsNotRecorded() {
        var t = HealthTracker()
        var p = probe(nil)
        p.verdicts = Array(repeating: .unmeasured, count: 5)
        p.internetChecks = [:]
        #expect(t.record(p, at: t0) == .unmeasured)
        #expect(t.samples.isEmpty)
    }

    @Test func settlingIgnoresFailuresUntilSomethingAnswers() {
        var t = HealthTracker()
        t.settle(at: t0)
        var dead = probe(nil)
        dead.internetChecks = ["example.com": false]
        #expect(t.record(dead, at: t0 + 3) == .settling)
        #expect(t.record(probe(15), at: t0 + 6) == .recorded)
        #expect(t.record(dead, at: t0 + 9) == .recorded)
        #expect(t.samples.count == 2)
    }

    @Test func settlingEndsAfterLimitSoRealOutagesShow() {
        var t = HealthTracker()
        t.settle(at: t0)
        var dead = probe(nil)
        dead.internetChecks = ["example.com": false]
        #expect(t.record(dead, at: t0 + Health.settleLimit - 1) == .settling)
        #expect(t.record(dead, at: t0 + Health.settleLimit) == .recorded)
        #expect(t.report(now: t0 + Health.settleLimit)?.score == 0)
    }

    @Test func futureSamplesAreDropped() {
        var t = HealthTracker()
        for i in 0..<5 { t.record(probe(15), at: t0 + 1000 + Double(i)) }
        t.record(probe(15), at: t0)
        #expect(t.samples.count == 1)
    }

    func probe(_ ms: Double?) -> WanProbe {
        let v: V = ms.map { .wan($0) } ?? .noReply
        return WanProbe(ms: ms, source: ms == nil ? nil : .icmp, rejected: 0, failed: ms == nil ? 5 : 0,
                        total: 5, verdicts: Array(repeating: v, count: 5), gatewayMs: nil, captive: false, internetChecks: ["example.com": true])
    }

    let t0: Double = 1_000_000

    @Test func dropsCyclesOutsideWindow() {
        var t = HealthTracker()
        for i in 0..<5 { t.record(probe(nil), at: t0 + Double(i) * 3) }
        let later = t0 + Health.window + 30
        for i in 0..<5 { t.record(probe(15), at: later + Double(i) * 3) }
        #expect(t.samples.count == 5)
        #expect(t.report(now: later + 12)?.loss == 0)
    }

    @Test func reportIgnoresStaleHistoryAfterSleep() {
        var t = HealthTracker()
        for i in 0..<5 { t.record(probe(15), at: t0 + Double(i) * 3) }
        #expect(t.report(now: t0 + 12) != nil)
        #expect(t.report(now: t0 + 3600) == nil)
    }

    @Test func resetClearsHistory() {
        var t = HealthTracker()
        let now = t0
        for _ in 0..<5 { t.record(probe(15), at: now) }
        t.reset()
        #expect(t.report(now: now) == nil)
    }
}

@Suite struct HealthDisplayTests {
    @Test func outageAndRecoveryBypassSmoothing() {
        var d = HealthDisplay()
        d.add(report(100)); _ = d.publish(now: 0)
        d.add(report(100))
        var offline = report(0)
        offline.internetReachable = false
        d.add(offline)
        let failed = d.publish(now: 1)
        #expect(failed)
        #expect(d.shown?.score == 0)
        #expect(d.shown?.internetReachable == false)
        d.add(offline)
        d.add(report(80))
        let recovered = d.publish(now: 2)
        #expect(recovered)
        #expect(d.shown?.score == 80)
        #expect(d.shown?.internetReachable == true)
    }

    func report(_ score: Int, loss: Double = 0) -> HealthReport {
        HealthReport(score: score, loss: loss, jitterMs: 10, latencyMs: 20)
    }

    @Test func firstReportShowsImmediately() {
        var d = HealthDisplay()
        let empty = d.publish(now: 0)
        #expect(!empty)
        d.add(report(90))
        let first = d.publish(now: 0)
        #expect(first)
        #expect(d.shown?.score == 90)
    }

    @Test func updatesAtMostOncePerInterval() {
        var d = HealthDisplay()
        d.add(report(90)); _ = d.publish(now: 0)
        d.add(report(50))
        let early = d.publish(now: Health.displayInterval - 1)
        #expect(!early)
        #expect(d.shown?.score == 90)
        let due = d.publish(now: Health.displayInterval)
        #expect(due)
        #expect(d.shown?.score == 50)
    }

    @Test func showsMeanOfReportsInInterval() {
        var d = HealthDisplay()
        d.add(report(100)); _ = d.publish(now: 0)
        d.add(report(100, loss: 0)); d.add(report(70, loss: 0.1)); d.add(report(85, loss: 0.2))
        _ = d.publish(now: Health.displayInterval)
        #expect(d.shown?.score == 85)
        #expect(abs((d.shown?.loss ?? 0) - 0.1) < 1e-9)
    }

    @Test func keepsValueWhenNothingNewArrives() {
        var d = HealthDisplay()
        d.add(report(80)); _ = d.publish(now: 0)
        let changed = d.publish(now: 100)
        #expect(!changed)
        #expect(d.shown?.score == 80)
    }

    @Test func resetHidesValue() {
        var d = HealthDisplay()
        d.add(report(80)); _ = d.publish(now: 0)
        d.reset()
        #expect(d.shown == nil)
        d.add(report(60))
        let shown = d.publish(now: 1)
        #expect(shown)
        #expect(d.shown?.score == 60)
    }
}

@Suite struct StatusLayoutTests {
    @Test func widthGrowsImmediately() {
        var w = StableWidth()
        let a = w.fit(100, now: 0), b = w.fit(120, now: 1)
        #expect(a == 100)
        #expect(b == 120)
    }

    @Test func widthShrinksOnlyAfterStayingNarrower() {
        var w = StableWidth()
        _ = w.fit(120, now: 0)
        let a = w.fit(90, now: 1), b = w.fit(100, now: 20), c = w.fit(95, now: 1 + StableWidth.shrinkAfter)
        #expect(a == 120)
        #expect(b == 120)
        #expect(c == 100)
    }

    @Test func returningToFullWidthCancelsShrink() {
        var w = StableWidth()
        _ = w.fit(120, now: 0)
        _ = w.fit(90, now: 1)
        _ = w.fit(120, now: 10)
        let a = w.fit(90, now: 35)
        #expect(a == 120)
    }
}

@Suite struct DecideVerdictTests {
    @Test func verdictsKeepTargetOrder() {
        let echoes: [Latency.EchoReply?] = [
            Latency.EchoReply(ms: 25, hops: 10), nil, Latency.EchoReply(ms: 1, hops: 1)
        ]
        let r = Latency.decide(echoes: echoes, gatewayMs: nil, portal: .internet, internetChecks: ["example.com": true], httpFallback: { nil })
        #expect(r.verdicts == [.wan(25), .noReply, .onPath])
    }
}
