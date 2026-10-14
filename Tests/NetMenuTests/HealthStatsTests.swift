import Foundation
import Testing
@testable import NetMenu

@Suite struct HealthStatsTests {
    @Test func diagnosticSnapshotSurvivesJSONRoundTrip() throws {
        let report = HealthReport(score: 94, loss: 0.03, jitterMs: 12, latencyMs: 45,
                                  internetReachable: true, websitesFailing: true)
        let snapshot = HealthStatsSnapshot(report: report, transport: report, local: report,
            reconnects5m: 1,
            recentTrouble: ["network loss"], webChecksFresh: true)
        let line = try #require(jsonLine(snapshot.json))
        let obj = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(obj["reconnects_5m"] as? Int == 1)
        #expect(obj["health_raw"] as? Int == 94)
        #expect(obj["health_loss"] as? Double == 0.03)
        #expect(obj["health_jitter_ms"] as? Double == 12)
        #expect(obj["health_latency_ms"] as? Double == 45)
        #expect(obj["health_weighting"] as? String == "inverse_sqrt_age")
        #expect(obj["health_window_s"] as? Double == 60)
        #expect(obj["recent_trouble"] as? [String] == ["network loss"])
        #expect(obj["internet_checks_fresh"] as? Bool == true)
    }

    @Test func unavailableEvidenceIsNullNotZero() throws {
        let snapshot = HealthStatsSnapshot(report: nil, transport: nil, local: nil,
            reconnects5m: 0,
            recentTrouble: [], webChecksFresh: false)
        let line = try #require(jsonLine(snapshot.json))
        let obj = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(obj["health_raw"] is NSNull)
        #expect(obj["health_loss"] is NSNull)
        #expect(obj["health_internet_reachable"] is NSNull)
        #expect(obj["transport_health"] is NSNull)
        #expect(obj["recent_trouble"] as? [String] == [])
        #expect(obj["reconnects_5m"] as? Int == 0)
    }
}
