import Foundation
import Testing
@testable import NetMenu

@Suite struct HealthRecencyTests {
    private func sample(at: Double, ms: Double?, http: Bool = false) -> HealthSample {
        HealthSample(at: at, ms: ms, source: http ? .http : .icmp,
                     targets: http ? [] : [ms.map { .wan($0) } ?? .noReply], internet: .reachable)
    }

    @Test func requestedWeightsAndWindowBoundary() {
        #expect(Health.recencyWeight(age: 0) == 1)
        #expect(Health.recencyWeight(age: 0.5) == 1)
        #expect(Health.recencyWeight(age: 1) == 1)
        #expect(abs(Health.recencyWeight(age: 30) - sqrt(1.0 / 30)) < 1e-12)
        #expect(abs(Health.recencyWeight(age: 60) - sqrt(1.0 / 60)) < 1e-12)
        #expect(Health.recencyWeight(age: 60.001) == 0)
    }

    @Test(arguments: [false, true]) func recentLossCountsMoreThanOldLoss(http: Bool) throws {
        let recent = [sample(at: 0, ms: 20, http: http), sample(at: 30, ms: 20, http: http), sample(at: 59, ms: nil, http: http)]
        let old = [sample(at: 0, ms: nil, http: http), sample(at: 30, ms: 20, http: http), sample(at: 59, ms: 20, http: http)]
        let a = try #require(Health.evaluate(recent, now: 60))
        let b = try #require(Health.evaluate(old, now: 60))
        let total = 1 / sqrt(60.0) + 1 / sqrt(30.0) + 1
        #expect(abs(a.loss - 1 / total) < 1e-12)
        #expect(abs(b.loss - (1 / sqrt(60.0)) / total) < 1e-12)
        #expect(a.score < b.score)
    }

    @Test func latencyUsesWeightedMedianAndJitterUsesNewerReplyAge() throws {
        let samples = [sample(at: 0, ms: 20), sample(at: 30, ms: 20), sample(at: 59, ms: 600)]
        let report = try #require(Health.evaluate(samples, now: 60))
        #expect(report.latencyMs == 600)
        #expect(abs((report.jitterMs ?? 0) - 580 / (1 + 1 / sqrt(30.0))) < 1e-9)
        let oldSpike = [sample(at: 0, ms: 600), sample(at: 30, ms: 20), sample(at: 59, ms: 20)]
        let old = try #require(Health.evaluate(oldSpike, now: 60))
        #expect(old.latencyMs == 20)
        #expect((old.jitterMs ?? 0) < (report.jitterMs ?? 0))
        #expect(old.score > report.score)
    }

    @Test func expiredSamplesDoNotAffectCalibrationOrScore() {
        let samples = [sample(at: -0.01, ms: nil), sample(at: 0, ms: 20), sample(at: 30, ms: 20), sample(at: 59, ms: 20)]
        #expect(Health.evaluate(samples, now: 60)?.score == 100)
        #expect(Health.evaluate(samples, now: 60.01) == nil)
    }

    @Test func liveTrackerUsesTheReportClockForAge() throws {
        var live = LiveHealthTracker()
        live.recordTarget(slot: 0, verdict: .wan(20), started: 0, at: 0)
        live.recordTarget(slot: 0, verdict: .wan(20), started: 30, at: 30)
        live.recordTarget(slot: 0, verdict: .noReply, started: 59, at: 59)
        let a = try #require(live.transportReport(now: 59))
        let b = try #require(live.transportReport(now: 60))
        #expect(b.loss > a.loss) // Older successes decay while the newest sample is capped at weight 1.
    }
}
