import Foundation
import Testing
@testable import NetMenu

private final class StartupApp: AppDelegate {
    var starts = 0
    var resets = 0
    var displays = 0
    override func startAppBandwidth() { starts += 1 }
    override func resetAppBandwidth(at: TimeInterval = BandwidthClock.now()) { resets += 1 }
    override func appendStatsLine(_ line: String) {}
    override func updateTitle() { displays += 1 }
}

@Suite @MainActor struct StartupTests {
    private func wifi(router: String = "192.168.1.1", named: Bool = false) -> Identity {
        Identity(iface: "en0", type: NetType.wifi, network: named ? "Home" : PortName.wifi,
                 bssid: named ? "aa:bb:cc:dd:ee:ff" : nil, router: router,
                 rssi: nil, noise: nil, txRate: nil, channel: nil)
    }

    @Test func ticksCannotPublishOrProbeBeforeInitialIdentity() {
        let app = StartupApp()
        let counters = Counters(rx: ["en0": 1000], tx: ["en0": 500])
        app.tick(counters: counters, at: 1)
        app.tick(counters: counters, at: 10)
        #expect(app.displays == 0)
        #expect(app.bandwidth.window.sampleCount == 0)
        #expect(app.lastCycleAt == nil)
        #expect(!app.hasResolvedIdentity)
    }

    @Test func initialDiscoveryDoesNotResetAndNameEnrichmentPreservesReadings() {
        let app = StartupApp()
        let initialEpoch = app.snapshotProbeContext().epoch
        app.applyIdentity(wifi())
        #expect(app.hasResolvedIdentity)
        #expect(app.starts == 1)
        #expect(app.resets == 0)
        #expect(app.snapshotProbeContext().epoch == initialEpoch)
        app.noteLatency(20, src: LatencySource.icmp.rawValue)
        app.applyIdentity(wifi(named: true))
        #expect(app.recentLats == [20])
        #expect(app.starts == 1)
        #expect(app.resets == 0)
        #expect(app.snapshotProbeContext().epoch == initialEpoch)
    }

    @Test func realNetworkChangeStillResets() {
        let app = StartupApp()
        app.applyIdentity(wifi())
        app.noteLatency(20, src: LatencySource.icmp.rawValue)
        let initialEpoch = app.snapshotProbeContext().epoch
        app.applyIdentity(wifi(router: "192.168.2.1"))
        #expect(app.resets == 1)
        #expect(app.recentLats.isEmpty)
        #expect(app.lastLatMs == nil)
        #expect(app.snapshotProbeContext().epoch == initialEpoch + 1)
        #expect(app.starts == 1)
    }

    @Test func offlineDiscoveryCompletesInitialization() {
        let app = StartupApp()
        app.applyIdentity(app.identity)
        #expect(app.hasResolvedIdentity)
        #expect(app.starts == 1)
        app.applyIdentity(wifi())
        #expect(app.resets == 1)
    }
}
