import Foundation
import Testing
@testable import NetMenu

@Suite struct WiFiScanTests {
    private let base = Date(timeIntervalSince1970: 1_792_000_000)
    private func event(_ date: Date, _ message: String) -> [String: String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: -7 * 3600)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZZZ"
        return ["timestamp": f.string(from: date), "eventMessage": message]
    }
    private func evidence(source: String = "Wi-Fi") throws -> [WiFiScanEvidence.Scan] {
        var events: [[String: String]] = []
        for second in [0.0, 15.0] {
            events.append(event(base.addingTimeInterval(second), "SCAN request received from pid 5984 (\(source)) with priority=0"))
            events.append(event(base.addingTimeInterval(second + 3), "Apple80211Scan:1522 ifname['en0'], total time [3.000000]"))
        }
        let json = String(data: try JSONSerialization.data(withJSONObject: events.reversed().map { $0 }), encoding: .utf8)!
        return WiFiScanEvidence.scans(json: json)
    }
    private var samples: [WiFiScanEvidence.Sample] {
        [2.0, 17.0].map { .init(end: base.addingTimeInterval($0), ms: 90) }
    }

    @Test func repeatedSettingsScansAndOverlappingSpikesWarn() throws {
        let scans = try evidence()
        #expect(scans.count == 2)
        #expect(abs(scans[0].start.timeIntervalSince(base)) < 0.001)
        #expect(WiFiScanEvidence.hasProblem(samples: samples, scans: scans, now: base.addingTimeInterval(20)))
    }

    @Test func backgroundSourcesAndMalformedLogsNeverBlameSettings() throws {
        for name in ["locationd", "firefox", "WiFiAgent"] {
            #expect(try evidence(source: name).isEmpty)
        }
        #expect(WiFiScanEvidence.scans(json: "permission denied").isEmpty)
        #expect(WiFiScanEvidence.scans(json: "[]").isEmpty)
    }

    @Test func healthyUnrelatedSingleAndStaleSpikesDoNotWarn() throws {
        let scans = try evidence()
        let now = base.addingTimeInterval(20)
        #expect(!WiFiScanEvidence.hasProblem(samples: samples.map { .init(end: $0.end, ms: 5) }, scans: scans, now: now))
        #expect(!WiFiScanEvidence.hasProblem(samples: [.init(end: base.addingTimeInterval(10), ms: 90), .init(end: now, ms: 90)], scans: scans, now: now))
        #expect(!WiFiScanEvidence.hasProblem(samples: Array(samples.prefix(1)), scans: scans, now: now))
        #expect(!WiFiScanEvidence.hasProblem(samples: samples, scans: scans, now: base.addingTimeInterval(80)))
        #expect(!WiFiScanEvidence.hasProblem(samples: samples, scans: scans, now: base.addingTimeInterval(-1)))
    }

    @Test func multipleSpikesInOneScanAreInsufficient() throws {
        let scans = try evidence()
        let samples: [WiFiScanEvidence.Sample] = [1.0, 2.0].map { .init(end: base.addingTimeInterval($0), ms: 90) }
        #expect(!WiFiScanEvidence.hasProblem(samples: samples, scans: scans, now: base.addingTimeInterval(20)))
    }
}
