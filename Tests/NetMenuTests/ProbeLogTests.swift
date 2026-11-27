import Foundation
import Testing
@testable import NetMenu

@Suite struct ProbeLogTests {
    private final class Capture: @unchecked Sendable {
        var lines: [(category: String, message: String, date: Date)] = []
        lazy var log: ProbeLog = {
            var config = LoggingConfig()
            config.probeSummaryInterval = 60
            config.probeDetailWindow = 30
            return ProbeLog(config: config) { [unowned self] in self.lines.append(($0, $1, $2)) }
        }()
        var messages: [String] { lines.map(\.message) }
        func ping(_ second: TimeInterval, state: String = "reply", ms: Double? = 10) {
            log.record("probe", key: "1.1.1.1", state: state, ms: ms, at: Date(timeIntervalSince1970: second), now: second,
                       "target \(state) @\(Int(second))")
        }
    }

    @Test func repeatedResultsBecomeOneSummaryAMinute() {
        let c = Capture()
        c.ping(0, ms: 12)
        for second in stride(from: 40.0, to: 100, by: 3) { c.ping(second, ms: second == 43 ? 30 : 9) }
        // The first result of a kind is a change; everything after it is the same state.
        #expect(c.messages.first == "target reply @0")
        let summaries = c.messages.filter { $0.hasPrefix("summary") }
        #expect(summaries == ["summary 61s: 1.1.1.1 reply ×8 9.0/9.0/30.0ms"])
        // A clock set back by a day changes the timestamps written, not when summaries are due.
        c.log.record("probe", key: "1.1.1.1", state: "reply", ms: 9, at: Date(timeIntervalSince1970: -86_400), now: 170, "late")
        #expect(c.messages.last?.hasPrefix("summary 109s: 1.1.1.1 reply ×13") == true)
        c.lines.removeLast()
        #expect(c.lines.count == 2)
    }

    @Test func aChangeIsWrittenAtOnceWithTheResultsAroundIt() {
        let c = Capture()
        for second in stride(from: 0.0, through: 45, by: 3) { c.ping(second) }
        c.lines.removeAll()
        c.ping(48, state: "lost", ms: nil)
        // The first result was itself a change, so results up to second 30 were already written
        // individually. Those since are recalled, with their own times, before the new change.
        let recalled = c.lines.filter { $0.message.hasSuffix(ProbeLog.recalledMark) }
        #expect(recalled.first?.message == "target reply @30" + ProbeLog.recalledMark)
        #expect(recalled.first?.date == Date(timeIntervalSince1970: 30))
        #expect(recalled.count == 6)
        #expect(c.messages.last == "target lost @48")
        // A change does not cut the minute short; both states appear in the next summary.
        #expect(!c.messages.contains { $0.hasPrefix("summary") })

        // Results after a change are written individually for the detail window, then summarised.
        c.lines.removeAll()
        c.ping(51, state: "lost", ms: nil); c.ping(59, state: "lost", ms: nil)
        c.ping(77, state: "lost", ms: nil); c.ping(80, state: "lost", ms: nil)
        #expect(c.messages == ["target lost @51", "target lost @59",
                               "summary 77s: 1.1.1.1 reply ×16 10.0/10.0/10.0ms; 1.1.1.1 lost ×3", "target lost @77"])
    }

    @Test func otherKindsKeepTheirOwnStateAndDetail() {
        let c = Capture()
        let at = Date(timeIntervalSince1970: 0)
        c.log.record("health", key: "health", state: "100%", detail: "jitter=3.0", at: at, now: 0, "100% jitter=3.0")
        c.log.record("health", key: "health", state: "100%", detail: "jitter=4.5", at: at.addingTimeInterval(40), now: 40, "100% jitter=4.5")
        c.log.notable("probe", at: at.addingTimeInterval(50), now: 50, "fallback 70.0")
        c.log.flush(at: at.addingTimeInterval(55), now: 55)
        #expect(c.messages == ["100% jitter=3.0", "100% jitter=4.5" + ProbeLog.recalledMark, "fallback 70.0",
                               "summary 55s: health 100% ×2 (jitter=4.5)"])
        c.log.flush(at: at.addingTimeInterval(56), now: 56)
        #expect(c.lines.count == 4)
    }
}
