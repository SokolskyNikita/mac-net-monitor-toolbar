import Foundation
import Testing
@testable import NetMenu

@Suite struct ConfigurationTests {
    @Test func healthOverridesReachScoringHistoryAndReset() {
        var config = HealthConfig()
        config.minCycles = 1
        config.window = 5
        config.processingAllowanceMs = 0
        config.freeDelayMs = 0
        config.delayHalfScaleMs = 100
        var local = LocalHealthTracker(config: config)
        var live = LiveHealthTracker(config: config)
        for at in [0.0, 20.0] {
            local.record(.reply(.init(ms: 200, hops: nil)), at: at)
            live.recordTarget(slot: 0, verdict: .wan(200), started: at, at: at)
            #expect(local.report(now: at)?.score == 50)
            #expect(live.report(now: at)?.score == 50)
            #expect(local.report(now: at + 6) == nil)
            #expect(live.report(now: at + 6) == nil)
            local.reset(); live.reset()
        }
        // Overrides are values; they must not mutate the process defaults.
        #expect(Health.rawScore(loss: 0, jitterMs: 0, latencyMs: 200) == 100)
        let snapshot = HealthStatsSnapshot(report: nil, transport: nil, local: nil,
            reconnects5m: 0, recentTrouble: [], webChecksFresh: false, config: config)
        #expect(snapshot.json["health_window_s"] as? Double == 5)
    }

    @Test func displayOverrideSurvivesReset() {
        var config = HealthConfig()
        config.displayInterval = 2
        var display = HealthDisplay(config: config)
        for at in [0.0, 20.0] {
            display.add(.init(score: 100, loss: 0, jitterMs: nil, latencyMs: 10))
            let first = display.publish(now: at)
            #expect(first)
            display.add(.init(score: 50, loss: 0, jitterMs: nil, latencyMs: 10))
            let early = display.publish(now: at + 1)
            #expect(!early)
            let next = display.publish(now: at + 2)
            #expect(next)
            #expect(display.shown?.score == 50)
            display.reset()
        }
    }

    @Test func monitoringFreshnessOverridesSurviveReset() {
        var config = MonitoringConfig()
        config.websiteFreshFor = 2
        config.latencyStaleAfter = 2
        config.displayLatencyReadings = 1
        var live = LiveHealthTracker(monitoring: config)
        for at in [0.0, 20.0] {
            live.recordWeb(["site": true], at: at)
            live.recordTarget(slot: 0, verdict: .wan(10), started: at, at: at)
            live.recordTarget(slot: 0, verdict: .wan(20), started: at + 1, at: at + 1)
            #expect(live.latencyReadings(now: at + 1) == [20])
            #expect(live.hasFreshWebCheck(now: at + 2))
            #expect(!live.hasFreshWebCheck(now: at + 3))
            #expect(live.latencyReadings(now: at + 4).isEmpty)
            live.reset()
        }
    }

    @Test func bandwidthOverridesReachPeaksWindowsAndConnectionReset() {
        var config = MonitoringConfig()
        config.bandwidthDisplayInterval = 2
        config.bandwidthMinPeakInterval = 1.5
        func counters(_ bytes: UInt64) -> Counters { Counters(rx: ["en0": bytes]) }
        var tracker = BandwidthTracker(counters: counters(0), at: 0, config: config)
        for at in [0.0, 20.0] {
            #expect(tracker.record(counters(100), at: at + 1) == .sampled)
            #expect(tracker.record(counters(200), at: at + 2) == .displayUpdated)
            #expect(tracker.display.down == 100)
            #expect(tracker.peak.down == 0)
            #expect(tracker.window.peak.down == 0)
            tracker.resetConnection(counters: counters(0), at: 20)
        }
    }

    @Test func scanThresholdOverrideChangesEvidenceDecision() {
        let date = Date(timeIntervalSince1970: 100)
        let sample = WiFiScanEvidence.Sample(end: date, ms: 20)
        let scan = WiFiScanEvidence.Scan(start: date.addingTimeInterval(-1), end: date, settingsRequest: date)
        var config = MonitoringConfig()
        config.wifiScanSlowMs = 10
        config.wifiScanMinOverlaps = 1
        config.wifiScanMinRequests = 1
        config.wifiScanEvidenceWindow = 2
        #expect(WiFiScanEvidence.hasProblem(samples: [sample], scans: [scan], now: date, config: config))
        #expect(!WiFiScanEvidence.hasProblem(samples: [sample], scans: [scan], now: date))
        #expect(!WiFiScanEvidence.hasProblem(samples: [sample], scans: [scan], now: date.addingTimeInterval(3), config: config))
    }

    @Test func loggingOverrideControlsActualCompaction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stats.jsonl")
        var config = LoggingConfig()
        config.statsMaxBytes = 12
        config.statsTrimDivisor = 3
        let log = StatsLog(config: config)
        for line in ["a", "bb", "ccc", "ddd"] { try log.append(line, to: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "ccc\nddd\n")
    }

    @Test func dependentDurationsFollowChangedSamplingAndProbeCadences() {
        var config = MonitoringConfig()
        config.appSampleInterval = 20
        config.probeInterval = 4
        config.icmpTimeoutMs = 12_000
        var connections = ConnectionDisplay(config: config)
        connections.record(ConnectionCounts(), at: 0)
        #expect(connections.fresh(at: 24) != nil)
        #expect(connections.fresh(at: 26) == nil)
        #expect(config.healthyWebsiteInterval == 20)
        #expect(config.initialFallbackDelay == 12)
        #expect(config.cycleTimeout == 18)
        config.reconnectWindow = 120
        let snapshot = HealthStatsSnapshot(report: nil, transport: nil, local: nil,
            reconnects5m: 0, recentTrouble: [], webChecksFresh: false, monitoring: config)
        #expect(snapshot.json["reconnect_window_s"] as? Double == 120)
    }
}
