import AppKit
import Testing
@testable import NetMenu

@Suite struct TopBandwidthAppsTests {
    private func app(_ name: String, _ down: Double, _ up: Double = 0) -> AppBandwidthUsage {
        AppBandwidthUsage(id: name, name: name, downBytes: down, upBytes: up)
    }

    private func top(_ apps: [AppBandwidthUsage], total: Double = 100) -> TopBandwidthApps {
        TopBandwidthApps(AppBandwidthSnapshot(apps: apps, totalBytes: total, seconds: 5))
    }

    @Test func stopsAtOneTwoOrThreeAsSoonAsEightyPercentIsReached() {
        #expect(top([app("A", 80), app("B", 20)]).apps.map(\.name) == ["A"])
        #expect(top([app("B", 30), app("C", 20), app("A", 50)]).apps.map(\.name) == ["A", "B"])
        let three = top([app("A", 40), app("B", 25), app("C", 15), app("D", 10)])
        #expect(three.apps.map(\.name) == ["A", "B", "C"])
        #expect(three.reachedTarget)
    }

    @Test func capsAtThreeAndReportsActualCoverageWhenTargetIsImpossible() {
        let result = top([app("A", 25), app("B", 25), app("C", 25), app("D", 25)])
        #expect(result.apps.count == 3)
        #expect(result.share == 0.75)
        #expect(!result.reachedTarget)
        #expect(result.title == "Top apps (~75%): A, B, C")
    }

    @Test func ranksCombinedUploadAndDownloadAndUsesTotalIncludingUnattributedBytes() {
        let result = top([app("Download", 30), app("Upload", 0, 50)], total: 200)
        #expect(result.apps.map(\.name) == ["Upload", "Download"])
        #expect(result.share == 0.4)
        #expect(!result.reachedTarget)
    }

    @Test func combinesOnlyMatchingCallerIdentitiesBeforeRanking() {
        let result = top([
            AppBandwidthUsage(id: "caller:a", name: "Chrome", downBytes: 20, upBytes: 10),
            AppBandwidthUsage(id: "caller:a", name: "Chrome", downBytes: 20, upBytes: 0),
            AppBandwidthUsage(id: "caller:b", name: "Chrome", downBytes: 30, upBytes: 0),
            app("Other", 20),
        ])
        #expect(result.apps.map(\.id) == ["caller:a", "caller:b"])
        #expect(result.apps.first?.downBytes == 40)
        #expect(result.apps.first?.upBytes == 10)
        #expect(result.share == 0.8)
    }

    @Test func sameNamesAndTruncatedPrefixesNeverMergeDifferentIdentities() {
        let result = top([app("CURL", 25), app("curl", 25),
                          app("A very long application one", 25), app("A very long application two", 25)])
        #expect(result.apps.count == 3)
        #expect(result.apps.first?.downBytes == 25)
        #expect(result.share == 0.75)
    }

    @Test func mismatchedCountersNeverReportOverOneHundredPercent() {
        let result = top([app("A", 80), app("B", 80)], total: 100)
        #expect(result.apps.count == 2)
        #expect(result.share == 1)
    }

    @Test func noTrafficAndUnattributedTrafficAreDistinct() {
        #expect(top([app("Idle", 0)], total: 0).title == "Top apps: no traffic")
        #expect(top([], total: 100).title == "Top apps: no attributed traffic")
    }

    @Test func truncatesByGrapheme() {
        let name = "Very Long Application 👩🏽‍💻 Name"
        let result = top([app(name, 100)])
        #expect(TopBandwidthApps.shortName(name).count == 18)
        #expect(result.title.contains("…"))
        #expect(TopBandwidthApps.shortName("App\nWith\tSpaces") == "App With Spaces")
    }

    @Test func roundsDownBelowTheThreshold() {
        let result = top([app("A", 79.9)])
        #expect(!result.reachedTarget)
        #expect(result.title.contains("79%"))
    }

    @Test func wideGlyphsAlsoFitTheMenuNameBudget() {
        let shortened = TopBandwidthApps.menuName(String(repeating: "W", count: 18))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        #expect((shortened as NSString).size(withAttributes: attributes).width <= 100)
        #expect(shortened.hasSuffix("…"))
    }
}

@Suite @MainActor struct TopBandwidthAppsIntegrationTests {
    @Test func transientFailureAndConnectionResetKeepTheLastListUntilRecovery() {
        let app = AppDelegate()
        app.hasResolvedIdentity = true
        app.speedTestRunning = true // Exercise the display without launching network probes.
        app.topAppsItem = MenuReadoutItem(title: "", style: .compact)
        let snapshot = AppBandwidthSnapshot(apps: [
            AppBandwidthUsage(id: "browser", name: "Browser", downBytes: 90, upBytes: 10)
        ], totalBytes: 100, seconds: 10)
        app.showAppBandwidth(snapshot, at: 0)
        #expect(app.topAppsItem?.readoutTitle == "Top apps (~100%): Browser")
        app.showAppBandwidth(nil, at: 6)
        #expect(app.topAppsItem?.readoutTitle == "Top apps (~100%): Browser")
        app.resetAppBandwidth(at: 10)
        #expect(app.topAppsItem?.readoutTitle == "Top apps (last sample) (~100%): Browser")
        app.showAppBandwidth(snapshot, at: 15)
        #expect(app.topAppsItem?.readoutTitle == "Top apps (last sample) (~100%): Browser")
        app.tick(counters: nil, at: 20)
        #expect(app.topAppsItem?.readoutTitle == "Top apps (~100%): Browser")
        #expect(app.topAppsItem?.toolTip == nil)
    }

    @Test func aStalledCollectorKeepsABoundedLastSampleThenBecomesUnavailable() {
        let app = AppDelegate()
        app.hasResolvedIdentity = true
        app.speedTestRunning = true // Exercise the display without launching network probes.
        app.topAppsItem = MenuReadoutItem(title: "", style: .compact)
        app.showAppBandwidth(AppBandwidthSnapshot(apps: [], totalBytes: 0, seconds: 5), at: 0)
        app.tick(counters: nil, at: 16)
        #expect(app.topAppsItem?.readoutTitle == "Top apps (last sample): no traffic")
        app.tick(counters: nil, at: 61)
        #expect(app.topAppsItem?.readoutTitle == "Top apps: unavailable")
    }
}

@Suite struct AppBandwidthDisplayTests {
    private let active = AppBandwidthSnapshot(apps: [
        AppBandwidthUsage(id: "curl", name: "curl", downBytes: 80, upBytes: 20)
    ], totalBytes: 100, seconds: 10)

    @Test func startupRetriesBeforeReportingAnExceptionalFailure() {
        var display = AppBandwidthDisplay()
        #expect(display.title(at: 0) == "Top apps: measuring…")
        display.record(nil, at: 5)
        display.record(nil, at: 11)
        #expect(display.title(at: 11) == "Top apps: measuring…")
        display.record(nil, at: 18)
        #expect(display.title(at: 18) == "Top apps: unavailable")
        display.record(active, at: 24)
        #expect(display.title(at: 24) == "Top apps: unavailable")
        #expect(display.title(at: 28) == "Top apps (~100%): curl")
    }

    @Test func oneOrRepeatedMissesDoNotDiscardTheLastGoodListOrExtendItsLifetime() {
        var display = AppBandwidthDisplay()
        display.record(active, at: 0)
        #expect(display.title(at: 0) == "Top apps (~100%): curl")
        for second in [6.0, 12, 18, 30, 60] {
            display.record(nil, at: second)
            _ = display.title(at: second)
        }
        #expect(display.title(at: 60) == "Top apps (last sample) (~100%): curl")
        #expect(display.title(at: 61) == "Top apps: unavailable")
    }

    @Test func unattributedTrafficKeepsLastListButActualIdleIsNotAFailure() {
        var display = AppBandwidthDisplay()
        display.record(active, at: 0)
        display.record(AppBandwidthSnapshot(apps: [], totalBytes: 100, seconds: 5), at: 5)
        #expect(display.title(at: 5) == "Top apps (last sample) (~100%): curl")
        display.record(AppBandwidthSnapshot(apps: [], totalBytes: 0, seconds: 5), at: 10)
        #expect(display.title(at: 10) == "Top apps (last sample) (~100%): curl")
        #expect(display.title(at: 15) == "Top apps: no traffic")
    }

    @Test func wakingFromSleepRecalibratesInsteadOfReportingAnExceptionalFailure() {
        var display = AppBandwidthDisplay()
        display.record(active, at: 0)
        display.restart(at: 3_600)
        #expect(display.title(at: 3_600) == "Top apps: measuring…")
        display.record(active, at: 3_610)
        #expect(display.title(at: 3_610) == "Top apps (~100%): curl")
    }

    @Test func holdsTheVisibleListForTenSecondsIncludingFasterRecoveryReadings() {
        var display = AppBandwidthDisplay()
        display.record(active, at: 10)
        #expect(display.title(at: 10) == "Top apps (~100%): curl")
        let browser = AppBandwidthSnapshot(apps: [
            AppBandwidthUsage(id: "Browser", name: "Browser", downBytes: 90, upBytes: 10)
        ], totalBytes: 100, seconds: 10)
        display.record(browser, at: 15)
        #expect(display.title(at: 15) == "Top apps (~100%): curl")
        #expect(display.title(at: 19.99) == "Top apps (~100%): curl")
        #expect(display.title(at: 20) == "Top apps (~100%): Browser")
    }

    @Test func idleTimerTicksDoNotDelayTheNextCompleteWindow() {
        var display = AppBandwidthDisplay()
        for second in 0...10 { #expect(display.title(at: Double(second)) == "Top apps: measuring…") }
        display.record(active, at: 10.2)
        #expect(display.title(at: 10.2) == "Top apps (~100%): curl")
        for second in 11...20 { #expect(display.title(at: Double(second)) == "Top apps (~100%): curl") }
        display.record(AppBandwidthSnapshot(apps: [
            AppBandwidthUsage(id: "Browser", name: "Browser", downBytes: 100, upBytes: 0)
        ], totalBytes: 100, seconds: 10), at: 20.4)
        #expect(display.title(at: 20.4) == "Top apps (~100%): Browser")
    }
}
