import Foundation
import Testing
@testable import NetMenu

@Suite struct ProbeStatsTests {
    @Test func unmeasuredProbesAreExcludedButRejectedRepliesCountAsLoggedLoss() {
        var window = ProbeStatsWindow(at: 10)
        window.recordWAN(.unmeasured)
        #expect(!window.hasMeasurements)
        window.recordWAN(.wan(20))
        window.recordWAN(.noReply)
        window.recordWAN(.onPath)
        #expect(window.total == 3)
        #expect(window.rejected == 1)
        #expect(window.loss == 2.0 / 3)
        #expect(window.latencies == [20])
        #expect(window.startedAt == 10)
    }

    @Test func transportChangesResetOnlyLatencyAndEmptyWindowsHaveNoUsableLatency() {
        var window = ProbeStatsWindow(at: 0)
        window.recordWAN(.noReply)
        #expect(window.hasMeasurements)
        #expect(window.loss == 1)
        window.recordWAN(.wan(20))
        window.recordRouter(2)
        window.recordLatency(200, source: "http")
        #expect(window.latencies == [200])
        #expect(window.latencySource == "http")
        #expect(window.routerLatencies == [2])
        #expect(window.loss == 0.5)
        window.recordWAN(.wan(30))
        #expect(window.latencies == [30])
        #expect(window.latencySource == "icmp")
        #expect(window.total == 3)
    }

    @Test func successfulHTTPSWithoutMeasuredPingsIsNotLoggedAsLoss() {
        var window = ProbeStatsWindow(at: 0)
        window.recordWAN(.unmeasured)
        window.recordLatency(200, source: "http")
        #expect(window.hasMeasurements)
        #expect(window.loss == 0)
        window.recordLatency(.nan, source: "icmp")
        #expect(window.latencies == [200])
        #expect(window.latencySource == "http")
    }

    @Test func retainedReadingsAreBoundedWithoutDroppingPacketCounts() {
        var window = ProbeStatsWindow(at: 0)
        for ms in 0..<130 {
            window.recordWAN(.wan(Double(ms)))
            window.recordRouter(Double(ms))
        }
        #expect(window.latencies == (10..<130).map(Double.init))
        #expect(window.routerLatencies == window.latencies)
        #expect(window.total == 130)
    }
}
