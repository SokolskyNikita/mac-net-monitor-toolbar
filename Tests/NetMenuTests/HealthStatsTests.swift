import Foundation
import Testing
@testable import NetMenu

@Suite struct HealthStatsTests {
    @Test func typedSpeedStatusesKeepTheirJSONWireValues() throws {
        let identity = Identity(iface: nil, type: "offline", network: nil, bssid: nil,
            router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
        var failed = SpeedTestResult()
        failed.networkChanged = true
        var cancelled = SpeedTestResult()
        cancelled.cancelled = true
        var partial = SpeedTestResult()
        partial.download = SpeedPhaseResult(direction: .download, mbps: 12)
        var complete = partial
        complete.upload = SpeedPhaseResult(direction: .upload, mbps: 3)
        for (result, expected) in [(failed, "failed"), (cancelled, "cancelled"), (partial, "partial"), (complete, "ok")] {
            let line = try #require(jsonLine(SpeedTestStatsSnapshot(result: result, identity: identity).json))
            let json = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(json["status"] as? String == expected)
        }
    }

    @Test func speedTestEventRetainsPartialResultsAndOriginalNetwork() throws {
        let identity = Identity(iface: "en0", type: "wifi", network: "Original network", bssid: nil,
            router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
        var result = SpeedTestResult()
        result.download = SpeedPhaseResult(direction: .download, bytes: 2000, mbps: 12,
            streams: 4, budgetLimited: true, loadedLatencyMs: 50)
        result.cancelled = true
        result.bytesReserved = 4000
        let line = try #require(jsonLine(SpeedTestStatsSnapshot(result: result, identity: identity).json))
        let obj = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(obj["event"] as? String == "speedtest")
        #expect(obj["status"] as? String == "partial")
        #expect(obj["network"] as? String == "Original network")
        #expect(obj["down_mbps"] as? Double == 12)
        #expect(obj["down_lower_bound"] as? Bool == true)
        #expect(obj["up_mbps"] is NSNull)
        #expect(obj["bytes_reserved"] as? Int == 4000)
        result.networkChanged = true
        let failed = SpeedTestStatsSnapshot(result: result, identity: identity).json
        #expect(failed["status"] as? String == "failed")
        #expect((failed["errors"] as? [String: String])?["network"] != nil)
    }

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
        #expect(obj["health_weighting"] as? String == "exponential_age")
        #expect(obj["health_window_s"] as? Double == 60)
        #expect(obj["health_model"] as? String == "delay_budget_v2")
        #expect(obj["health_weight_half_life_s"] as? Double == 15)
        #expect(obj["health_weight_min_age_s"] == nil)
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
