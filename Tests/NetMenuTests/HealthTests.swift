import Testing
@testable import NetMenu

private typealias V = Latency.EchoVerdict

/// One probe cycle. By default all five targets answered with `ms`, or all were lost when `ms` is nil.
private func cycle(_ ms: Double?, source: LatencySource = .icmp, targets: [V]? = nil, at: Double = 0) -> HealthSample {
    let t = targets ?? Array(repeating: ms.map { .wan($0) } ?? .noReply, count: 5)
    return HealthSample(at: at, ms: ms, source: ms == nil ? nil : source, targets: t)
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
            cycle(i % 2 == 0 ? 125 : 160, targets: [i < 2 ? .noReply : .wan(125), .wan(125), .wan(125), .wan(125), .wan(125)])
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
        func withLoss(_ lostCycles: Int) -> Int {
            score((0..<20).map { i in
                cycle(20, targets: [i < lostCycles ? .noReply : .wan(20), .wan(20), .wan(20), .wan(20), .wan(20)])
            })
        }
        #expect(withLoss(0) == 100)
        #expect(withLoss(2) == 100)
        let scores = [2, 3, 5, 10, 15].map(withLoss)
        #expect(zip(scores, scores.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test func sevenPercentLossRoughlyHalvesScore() {
        // 7 of 100 echoes lost: 5 points past Zoom's 2% limit.
        let samples = (0..<20).map { i in
            cycle(20, targets: [i < 7 ? .noReply : .wan(20), .wan(20), .wan(20), .wan(20), .wan(20)])
        }
        let r = try! #require(Health.evaluate(samples))
        #expect(abs(r.loss - 0.07) < 1e-9)
        #expect(r.score >= 45 && r.score <= 52)
    }

    @Test func targetThatNeverAnswersIsNotLoss() {
        // Quad9 blocked on this network: every cycle, one target silent.
        let samples = (0..<10).map { _ in cycle(20, targets: [.wan(20), .wan(22), .wan(25), .noReply, .wan(30)]) }
        #expect(Health.evaluate(samples)?.loss == 0)
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

@Suite struct HealthTrackerTests {
    func probe(_ ms: Double?) -> WanProbe {
        let v: V = ms.map { .wan($0) } ?? .noReply
        return WanProbe(ms: ms, source: ms == nil ? nil : .icmp, rejected: 0, failed: ms == nil ? 5 : 0,
                        total: 5, verdicts: Array(repeating: v, count: 5), gatewayMs: nil, captive: false)
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
    @Test(arguments: [0, 7, 999, 999.6, 7_000, 38_000, 999_499, 999_600, 1_234_567, 9_949_999,
                      9_960_000, 123_456_789, 999_600_000, 1.5e9, 9.96e9, 42e9])
    func rateFitsFourCharacters(bps: Double) {
        #expect(fmtRate(bps).count <= 4)
    }

    @Test(arguments: [(0.0, "0B"), (7_000, "7K"), (999_600, "1.0M"), (12_300_000, "12M"), (2.5e9, "2.5G")])
    func rateFormat(bps: Double, text: String) {
        #expect(fmtRate(bps) == text)
    }

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
        let r = Latency.decide(echoes: echoes, gatewayMs: nil, portal: .internet, httpFallback: { nil })
        #expect(r.verdicts == [.wan(25), .noReply, .onPath])
    }
}
