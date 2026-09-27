import Testing
@testable import NetMenu

private func counters(_ rx: UInt64, _ tx: UInt64) -> Counters {
    Counters(rx: ["en0": rx], tx: ["en0": tx])
}

private func expectApproximatelyEqual(_ actual: Double, _ expected: Double) {
    let tolerance = max(1, abs(expected)) * 1e-12
    #expect(abs(actual - expected) <= tolerance)
}

@Suite struct DeltaRatesTests {
    @Test func aggregatesInterfacesAndKeepsDirectionsAsymmetric() {
        let old = Counters(rx: ["en0": 100, "en1": 200], tx: ["en0": 1_000, "en1": 2_000])
        let new = Counters(rx: ["en0": 160, "en1": 230], tx: ["en0": 1_020, "en1": 2_015])

        let rates = deltaRates(old: old, new: new, dt: 2)

        #expect(rates.down == 45)
        #expect(rates.up == 17.5)
    }

    @Test func rejectsNonPositiveOrNonFiniteIntervals() {
        let old = counters(100, 200)
        let new = counters(150, 250)

        for dt in [0.0, -1.0, .infinity, .nan] {
            let rates = deltaRates(old: old, new: new, dt: dt)
            #expect(rates.down == 0)
            #expect(rates.up == 0)
        }
    }

    @Test func countsTenGigabitsPerSecondAcrossTwoAndFiveSecondIntervals() {
        let old = counters(0, 0)
        let afterTwoSeconds = counters(2_500_000_000, 1_000_000_000)
        let afterFiveMoreSeconds = counters(8_750_000_000, 3_500_000_000)

        let first = deltaRates(old: old, new: afterTwoSeconds, dt: 2)
        let second = deltaRates(old: afterTwoSeconds, new: afterFiveMoreSeconds, dt: 5)

        #expect(first.down == 1_250_000_000)
        #expect(first.up == 500_000_000)
        #expect(second.down == 1_250_000_000)
        #expect(second.up == 500_000_000)
    }

    @Test func decreasesResetOnlyThatDirectionAndNeverWrap() {
        let old = counters(4_000_000_000, 500)
        let new = counters(0, 540)

        let rates = deltaRates(old: old, new: new, dt: 1)

        #expect(rates.down == 0)
        #expect(rates.up == 40)
    }

    @Test func subtractsNearUInt64MaximumBeforeConvertingToDouble() {
        let old = counters(UInt64.max - 7, UInt64.max - 11)
        let new = counters(UInt64.max, UInt64.max)

        let rates = deltaRates(old: old, new: new, dt: 1)

        #expect(rates.down == 7)
        #expect(rates.up == 11)
    }

    @Test func aggregatesUInt64DeltasWithoutOverflow() {
        let old = Counters(rx: ["en0": 0, "en1": 0], tx: ["en0": 0, "en1": 0])
        let new = Counters(rx: ["en0": .max, "en1": .max], tx: ["en0": .max, "en1": .max])

        let rates = deltaRates(old: old, new: new, dt: 1)
        let expected = Double(UInt64.max) * 2

        expectApproximatelyEqual(rates.down, expected)
        expectApproximatelyEqual(rates.up, expected)
    }

    @Test func addedRemovedAndMissingCountersAreHandledPerDirection() {
        let old = Counters(
            rx: ["rxOnly": 10, "removed": 100],
            tx: ["txOnly": 20, "removed": 200]
        )
        let new = Counters(
            rx: ["rxOnly": 35, "added": 900],
            tx: ["txOnly": 50, "added": 800]
        )

        let rates = deltaRates(old: old, new: new, dt: 1)

        #expect(rates.down == 25)
        #expect(rates.up == 30)
    }
}

@Suite struct BandwidthWindowTests {
    @Test func timeWeightsEachSampleByItsElapsedSeconds() {
        var window = BandwidthWindow()
        window.add(BandwidthRates(down: 900, up: 450), seconds: 1)
        window.add(BandwidthRates(down: 100, up: 50), seconds: 4)

        #expect(window.sampleCount == 2)
        #expect(window.seconds == 5)
        #expect(window.average.down == 260)
        #expect(window.average.up == 130)
        #expect(window.peak.down == 900)
        #expect(window.peak.up == 450)
    }

}

@Suite struct BandwidthTrackerTests {
    @Test func failedReadPreservesTheLastGoodBaselineAndDoesNotAddZeroTraffic() {
        var tracker = BandwidthTracker(counters: counters(0, 0), at: 0)
        _ = tracker.record(counters(900, 450), at: 1)

        #expect(tracker.record(nil, at: 2) == .unavailable)
        #expect(tracker.window.sampleCount == 1)
        #expect(tracker.window.seconds == 1)
        #expect(tracker.record(counters(1_300, 650), at: 5) == .displayUpdated)
        #expect(tracker.display == BandwidthRates(down: 260, up: 130))
        #expect(tracker.window.sampleCount == 2)
        #expect(tracker.window.seconds == 5)

        #expect(tracker.record(nil, at: 6) == .unavailable)
        #expect(tracker.display == BandwidthRates())
        #expect(tracker.current == BandwidthRates())
        #expect(tracker.window.sampleCount == 2)
    }

    @Test func missingInitialReadRequiresAGoodBaselineBeforeCountingTraffic() {
        var tracker = BandwidthTracker(counters: nil, at: 0)
        #expect(tracker.record(counters(50_000, 20_000), at: 1) == .sampled)
        #expect(tracker.window.sampleCount == 0)
        _ = tracker.record(counters(50_100, 20_050), at: 2)
        #expect(tracker.current == BandwidthRates(down: 100, up: 50))
        #expect(tracker.window.seconds == 1)
    }

    @Test func tracksCurrentPeakAndElapsedTimeWeightedLoggingWindow() {
        var tracker = BandwidthTracker(counters: counters(0, 0), at: 0)

        #expect(tracker.record(counters(100, 20), at: 1) == .sampled)
        #expect(tracker.current.down == 100)
        #expect(tracker.current.up == 20)
        #expect(tracker.peak.down == 100)
        #expect(tracker.peak.up == 20)

        #expect(tracker.record(counters(400, 100), at: 2) == .sampled)
        #expect(tracker.current.down == 300)
        #expect(tracker.current.up == 80)
        #expect(tracker.peak.down == 300)
        #expect(tracker.peak.up == 80)
        #expect(tracker.window.sampleCount == 2)
        #expect(tracker.window.seconds == 2)
        #expect(tracker.window.average.down == 200)
        #expect(tracker.window.average.up == 50)
        #expect(tracker.window.peak.down == 300)
        #expect(tracker.window.peak.up == 80)
    }

    @Test func tracksTenGigabitsPerSecondOverUnequalIntervals() {
        var tracker = BandwidthTracker(counters: counters(0, 0), at: 0)

        #expect(tracker.record(counters(2_500_000_000, 1_000_000_000), at: 2) == .sampled)
        #expect(tracker.current.down == 1_250_000_000)
        #expect(tracker.current.up == 500_000_000)
        #expect(tracker.record(counters(8_750_000_000, 3_500_000_000), at: 7) == .displayUpdated)

        #expect(tracker.display.down == 1_250_000_000)
        #expect(tracker.display.up == 500_000_000)
        #expect(tracker.window.seconds == 7)
        #expect(tracker.window.average.down == 1_250_000_000)
        #expect(tracker.window.average.up == 500_000_000)
    }

    @Test func displayUsesElapsedTimeWeightsAndStartsAFreshBucketAfterPublication() {
        var tracker = BandwidthTracker(counters: counters(0, 0), at: 0)

        #expect(tracker.record(counters(900, 450), at: 1) == .sampled)
        #expect(tracker.record(counters(1_300, 650), at: 5) == .displayUpdated)
        #expect(tracker.display.down == 260)
        #expect(tracker.display.up == 130)

        // The next five-second display must use only these two samples.
        #expect(tracker.record(counters(2_300, 1_650), at: 6) == .sampled)
        #expect(tracker.record(counters(4_300, 3_650), at: 10) == .displayUpdated)
        #expect(tracker.display.down == 600)
        #expect(tracker.display.up == 600)
    }

    @Test func resetWindowClearsOnlyLoggingValuesAndPreservesPendingDisplaySamples() {
        var tracker = BandwidthTracker(counters: counters(0, 0), at: 0)
        _ = tracker.record(counters(100, 50), at: 1)
        _ = tracker.record(counters(300, 150), at: 2)

        tracker.resetWindow()

        #expect(tracker.current.down == 200)
        #expect(tracker.current.up == 100)
        #expect(tracker.peak.down == 200)
        #expect(tracker.peak.up == 100)
        #expect(tracker.window.sampleCount == 0)
        #expect(tracker.window.seconds == 0)
        #expect(tracker.window.average.down == 0)
        #expect(tracker.window.average.up == 0)
        #expect(tracker.window.peak.down == 0)
        #expect(tracker.window.peak.up == 0)

        #expect(tracker.record(counters(1_200, 600), at: 5) == .displayUpdated)
        #expect(tracker.display.down == 240)
        #expect(tracker.display.up == 120)
        #expect(tracker.window.sampleCount == 1)
        #expect(tracker.window.seconds == 3)
        #expect(tracker.window.average.down == 300)
        #expect(tracker.window.average.up == 150)
    }

    @Test func gapRetainsLoggingWindowAndPeakButClearsRatesAndDisplay() {
        var tracker = BandwidthTracker(counters: counters(0, 0), at: 0)
        for second in 1...5 {
            let update = tracker.record(counters(UInt64(second * 10), UInt64(second * 5)), at: Double(second))
            #expect(update == (second == 5 ? .displayUpdated : .sampled))
        }
        _ = tracker.record(counters(450, 225), at: 6)
        #expect(tracker.current.down == 400)
        #expect(tracker.current.up == 200)

        #expect(tracker.record(counters(100_000, 200_000), at: 20) == .gap(endedAt: 6))
        #expect(tracker.current.down == 0)
        #expect(tracker.current.up == 0)
        #expect(tracker.display.down == 0)
        #expect(tracker.display.up == 0)
        #expect(tracker.peak.down == 400)
        #expect(tracker.peak.up == 200)
        #expect(tracker.window.sampleCount == 6)
        #expect(tracker.window.seconds == 6)
        #expect(tracker.window.average.down == 75)
        #expect(tracker.window.average.up == 37.5)

        // The caller can flush the retained pre-gap logging window before starting a new one.
        tracker.resetWindow()
        for second in 1...4 {
            #expect(tracker.record(counters(UInt64(100_000 + second * 40), UInt64(200_000 + second * 20)),
                                   at: Double(20 + second)) == .sampled)
            #expect(tracker.display.down == 0)
            #expect(tracker.display.up == 0)
        }
        #expect(tracker.record(counters(100_200, 200_100), at: 25) == .displayUpdated)
        #expect(tracker.display.down == 40)
        #expect(tracker.display.up == 20)
        #expect(tracker.window.sampleCount == 5)
        #expect(tracker.window.seconds == 5)
        #expect(tracker.window.average.down == 40)
        #expect(tracker.window.average.up == 20)
    }

    @Test func ignoresNonFiniteTimestampsWithoutChangingTheBaseline() {
        var tracker = BandwidthTracker(counters: counters(100, 50), at: 1)

        #expect(tracker.record(counters(9_000, 9_000), at: .nan) == .ignored)
        #expect(tracker.current.down == 0)
        #expect(tracker.current.up == 0)
        #expect(tracker.window.sampleCount == 0)

        #expect(tracker.record(counters(250, 110), at: 2) == .sampled)
        #expect(tracker.current.down == 150)
        #expect(tracker.current.up == 60)
        #expect(tracker.window.sampleCount == 1)
    }

    @Test func zeroAndBackwardIntervalsRebaseWithoutAddingSamples() {
        var tracker = BandwidthTracker(counters: counters(0, 0), at: 10)

        #expect(tracker.record(counters(100, 50), at: 10) == .gap(endedAt: 10))
        #expect(tracker.current.down == 0)
        #expect(tracker.display.down == 0)
        #expect(tracker.window.sampleCount == 0)
        #expect(tracker.peak.down == 0)

        #expect(tracker.record(counters(110, 60), at: 9) == .gap(endedAt: 10))
        #expect(tracker.window.sampleCount == 0)
        #expect(tracker.peak.down == 0)

        #expect(tracker.record(counters(130, 80), at: 11) == .sampled)
        #expect(tracker.current.down == 10)
        #expect(tracker.current.up == 10)
        #expect(tracker.window.sampleCount == 1)
        #expect(tracker.window.seconds == 2)
        #expect(tracker.window.average.down == 10)
        #expect(tracker.window.average.up == 10)
    }

    @Test func clockRollbackRestartsDisplayCadenceAndPublishesAfterFiveSeconds() {
        var tracker = BandwidthTracker(counters: counters(0, 0), at: 0)
        for second in 1...5 {
            let update = tracker.record(counters(UInt64(second * 100), UInt64(second * 50)), at: Double(second))
            #expect(update == (second == 5 ? .displayUpdated : .sampled))
        }
        #expect(tracker.display.down == 100)
        #expect(tracker.display.up == 50)

        #expect(tracker.record(counters(100_000, 200_000), at: -3_595) == .gap(endedAt: 5))
        #expect(tracker.display.down == 0)
        #expect(tracker.display.up == 0)
        tracker.resetWindow()

        for second in 1...4 {
            #expect(tracker.record(counters(UInt64(100_000 + second * 40), UInt64(200_000 + second * 20)),
                                   at: Double(-3_595 + second)) == .sampled)
        }
        #expect(tracker.display.down == 0)
        #expect(tracker.display.up == 0)
        #expect(tracker.record(counters(100_200, 200_100), at: -3_590) == .displayUpdated)
        #expect(tracker.display.down == 40)
        #expect(tracker.display.up == 20)
    }

    @Test func connectionResetClearsCurrentDisplayPeakAndBothWindows() {
        var tracker = BandwidthTracker(counters: counters(0, 0), at: 0)
        _ = tracker.record(counters(100, 50), at: 1)
        _ = tracker.record(counters(300, 150), at: 2)
        #expect(tracker.record(counters(900, 450), at: 5) == .displayUpdated)
        #expect(tracker.display.down == 180)
        #expect(tracker.display.up == 90)
        _ = tracker.record(counters(1_500, 600), at: 6)

        tracker.resetConnection(counters: counters(10_000, 20_000), at: 6)

        #expect(tracker.current.down == 0)
        #expect(tracker.current.up == 0)
        #expect(tracker.display.down == 0)
        #expect(tracker.display.up == 0)
        #expect(tracker.peak.down == 0)
        #expect(tracker.peak.up == 0)
        #expect(tracker.window.sampleCount == 0)
        #expect(tracker.window.seconds == 0)

        #expect(tracker.record(counters(10_040, 20_010), at: 7) == .sampled)
        #expect(tracker.record(counters(10_100, 20_030), at: 8) == .sampled)
        #expect(tracker.record(counters(10_120, 20_050), at: 9) == .sampled)
        #expect(tracker.record(counters(10_220, 20_100), at: 10) == .sampled)
        #expect(tracker.record(counters(10_240, 20_130), at: 11) == .displayUpdated)

        #expect(tracker.display.down == 48)
        #expect(tracker.display.up == 26)
        #expect(tracker.peak.down == 100)
        #expect(tracker.peak.up == 50)
        #expect(tracker.window.sampleCount == 5)
        #expect(tracker.window.seconds == 5)
        #expect(tracker.window.average.down == 48)
        #expect(tracker.window.average.up == 26)
    }
}

@Suite struct BandwidthMeasurementTests {
    @Test func dividesByMeasuredElapsedTimeAndSleepsOnlyRequestedInterval() {
        var readValues = [counters(0, 0), counters(2_500_000_000, 1_000_000_000)]
        var clockValues = [100.0, 102.0]
        var events: [String] = []

        let result = measureBandwidth(
            interval: 1,
            read: {
                events.append("read")
                return readValues.removeFirst()
            },
            now: {
                events.append("now")
                return clockValues.removeFirst()
            },
            sleep: { seconds in
                events.append("sleep:\(seconds)")
            }
        )

        #expect(events == ["read", "now", "sleep:1.0", "read", "now"])
        #expect(result.seconds == 2)
        #expect(result.rates.down == 1_250_000_000)
        #expect(result.rates.up == 500_000_000)
    }

    @Test func invalidClockIntervalReturnsZeroDurationAndRates() {
        var readIndex = 0
        var clockValues = [5.0, 5.0]
        let snapshots = [counters(0, 0), counters(100, 50)]

        let result = measureBandwidth(
            interval: 1,
            read: {
                defer { readIndex += 1 }
                return snapshots[readIndex]
            },
            now: { clockValues.removeFirst() },
            sleep: { _ in }
        )

        #expect(result.seconds == 0)
        #expect(result.rates.down == 0)
        #expect(result.rates.up == 0)
    }
}

@Suite struct RateFormattingTests {
    @Test(arguments: [0, 7, 999, 999.6, 7_000, 38_000, 999_499, 999_600, 1_234_567, 9_949_999,
                      9_960_000, 123_456_789, 999_600_000, 1.5e9, 9.96e9, 42e9])
    func rateFitsFourCharacters(bps: Double) {
        #expect(fmtRate(bps).count <= 4)
    }

    @Test(arguments: [(0.0, "0B"), (7_000, "7K"), (999_600, "1.0M"), (12_300_000, "12M"), (2.5e9, "2.5G")])
    func rateFormat(bps: Double, text: String) {
        #expect(fmtRate(bps) == text)
    }
}
