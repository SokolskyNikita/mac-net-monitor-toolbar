import Foundation
import Testing
@testable import NetMenu

private final class BandwidthLoggingApp: AppDelegate {
    override init() {
        super.init()
        hasResolvedIdentity = true
        speedTestRunning = true // These counter tests must not launch real network probes.
    }
    var lines: [String] = []
    var displayedRates: [BandwidthRates] = []

    override func appendStatsLine(_ line: String) { lines.append(line) }
    override func updateTitle() { displayedRates.append(bandwidth.display) }
}

@Suite @MainActor struct BandwidthIntegrationTests {
    private func counters(_ down: UInt64, _ up: UInt64) -> Counters {
        Counters(rx: ["en0": down], tx: ["en0": up])
    }

    private func sample(_ line: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    @Test func gapLogsCompletedSamplesBeforeClearingAndRebasesTheNextWindow() throws {
        let app = BandwidthLoggingApp()
        app.bandwidth = BandwidthTracker(counters: counters(0, 0), at: 0)
        app.probeStats = ProbeStatsWindow(at: 0)
        for _ in 0..<9 { app.probeStats.recordWAN(.wan(15)) }
        app.probeStats.recordWAN(.noReply)
        app.tick(counters: counters(900, 90), at: 1)
        app.tick(counters: counters(1_300, 130), at: 5)

        app.tick(counters: counters(500_000, 100_000), at: 20)

        #expect(app.lines.count == 1)
        let beforeGap = try sample(try #require(app.lines.first))
        #expect(beforeGap["secs"] as? Double == 5)
        #expect(beforeGap["down_Bps"] as? Double == 260)
        #expect(beforeGap["up_Bps"] as? Double == 26)
        #expect(beforeGap["down_peak_Bps"] as? Double == 900)
        #expect(beforeGap["up_peak_Bps"] as? Double == 90)
        #expect(beforeGap["lat_ms"] as? Double == 15)
        #expect(beforeGap["loss"] as? Double == 0.1)
        #expect(beforeGap["health_weighting"] as? String == "exponential_age")
        #expect(beforeGap["reconnects_5m"] as? Int == 0)
        #expect(beforeGap["health_raw"] is NSNull)
        #expect(app.probeStats.latencies.isEmpty)
        #expect(app.probeStats.total == 0)
        #expect(app.probeStats.startedAt == 20)
        #expect(app.bandwidth.window.sampleCount == 0)
        #expect(app.displayedRates.last == BandwidthRates())

        app.tick(counters: counters(500_100, 100_050), at: 21)
        app.tick(counters: counters(500_900, 100_450), at: 25)
        app.flushLog(at: 25)

        #expect(app.lines.count == 2)
        let afterGap = try sample(try #require(app.lines.last))
        #expect(afterGap["secs"] as? Double == 5)
        #expect(afterGap["down_Bps"] as? Double == 180)
        #expect(afterGap["up_Bps"] as? Double == 90)
        #expect(afterGap["down_peak_Bps"] as? Double == 200)
        #expect(afterGap["up_peak_Bps"] as? Double == 100)
    }

    @Test func gapPreservesEvenAShortCompletedInterval() throws {
        let app = BandwidthLoggingApp()
        app.bandwidth = BandwidthTracker(counters: counters(0, 0), at: 0)
        app.probeStats = ProbeStatsWindow(at: 0)
        app.tick(counters: counters(250, 125), at: 0.25)
        app.tick(counters: counters(50_000, 50_000), at: 10)

        #expect(app.lines.count == 1)
        let logged = try sample(try #require(app.lines.first))
        #expect(logged["secs"] as? Double == 0.25)
        #expect(logged["down_Bps"] as? Double == 1_000)
        #expect(logged["up_Bps"] as? Double == 500)
        #expect(app.probeStats.startedAt == 10)
    }
}
