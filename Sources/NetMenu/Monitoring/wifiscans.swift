import AppKit

/// Correlates local RTT spikes with recorded scans; an open Settings app alone is not evidence.
struct WiFiScanEvidence {
    struct Sample {
        let end: Date
        let ms: Double
        var start: Date { end.addingTimeInterval(-ms / 1000) }
    }
    struct Scan {
        let start: Date
        let end: Date
        let settingsRequest: Date
    }

    static func scans(json: String, config: MonitoringConfig = Configuration.monitoring) -> [Scan] {
        guard let data = json.data(using: .utf8),
              let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZZZ"
        let requestRE = try! NSRegularExpression(pattern: #"SCAN request received from pid (\d+) \(Wi-Fi\)"#)
        let durationRE = try! NSRegularExpression(pattern: #"Apple80211Scan:[0-9]+.*total time \[([0-9.]+)\]"#)
        func capture(_ regex: NSRegularExpression, _ text: String) -> String? {
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        let entries = events.compactMap { event -> (Date, String)? in
            guard let stamp = event["timestamp"] as? String, let date = formatter.date(from: stamp),
                  let message = event["eventMessage"] as? String else { return nil }
            return (date, message)
        }.sorted { $0.0 < $1.0 }
        var request: Date?
        var result: [Scan] = []
        for (end, message) in entries {
            if message.contains("SCAN request received") {
                request = capture(requestRE, message) == nil ? nil : end
            }
            if let request, let raw = capture(durationRE, message), let duration = Double(raw),
               duration >= config.wifiScanMinDuration, duration <= config.wifiScanMaxDuration, !message.contains("Failed") {
                let start = end.addingTimeInterval(-duration)
                // Only associate a completed scan with a recent, preceding Settings request.
                if start >= request.addingTimeInterval(-config.wifiScanRequestTolerance), end.timeIntervalSince(request) <= config.wifiScanRequestMaxAge {
                    result.append(Scan(start: start, end: end, settingsRequest: request))
                }
            }
        }
        return result
    }

    static func hasProblem(samples: [Sample], scans: [Scan], now: Date, config: MonitoringConfig = Configuration.monitoring) -> Bool {
        let recent = scans.filter { now.timeIntervalSince($0.end) >= 0 && now.timeIntervalSince($0.end) <= config.wifiScanEvidenceWindow }
        let slow = samples.filter { $0.ms > config.wifiScanSlowMs && now.timeIntervalSince($0.end) >= 0 && now.timeIntervalSince($0.end) <= config.wifiScanEvidenceWindow }
        let overlaps = slow.filter { sample in recent.contains { $0.start <= sample.end && $0.end >= sample.start } }
        let requests = Set(recent.filter { scan in overlaps.contains { scan.start <= $0.end && scan.end >= $0.start } }.map(\.settingsRequest))
        return overlaps.count >= config.wifiScanMinOverlaps && requests.count >= config.wifiScanMinRequests
    }
}

/// Main-thread owned. Queries are bounded, off-main, and only run after repeated local spikes.
final class WiFiScanMonitor {
    private let config: MonitoringConfig
    init(config: MonitoringConfig = Configuration.monitoring) { self.config = config }
    private var samples: [WiFiScanEvidence.Sample] = []
    private var scans: [WiFiScanEvidence.Scan] = []
    private var lastQuery = Date.distantPast
    private var inFlight = false
    private var generation = 0
    private(set) var warning = false
    var didChange: (() -> Void)?

    func record(ms: Double, at date: Date = Date()) {
        guard ms.isFinite, ms >= 0, ms <= config.wifiScanMaxSampleMs else { return }
        samples.removeAll { date.timeIntervalSince($0.end) > config.wifiScanHistory }
        samples.append(.init(end: date, ms: ms))
        if samples.count > config.wifiScanMaxSamples { samples.removeFirst(samples.count - config.wifiScanMaxSamples) }
    }

    func reset() {
        generation += 1
        samples.removeAll(); scans.removeAll(); lastQuery = .distantPast
        setWarning(false)
    }

    private func setWarning(_ value: Bool) {
        guard warning != value else { return }
        warning = value
        didChange?()
    }

    func poll(isWiFi: Bool, now: Date = Date()) {
        let settings = NSRunningApplication.runningApplications(withBundleIdentifier: SystemApp.systemSettingsBundleID)
        guard isWiFi, !settings.isEmpty else {
            if !samples.isEmpty || !scans.isEmpty || warning { reset() }
            return
        }
        setWarning(WiFiScanEvidence.hasProblem(samples: samples, scans: scans, now: now, config: config))
        guard !inFlight, now.timeIntervalSince(lastQuery) >= config.wifiScanQueryInterval,
              samples.filter({ $0.ms > config.wifiScanSlowMs && now.timeIntervalSince($0.end) >= 0 && now.timeIntervalSince($0.end) <= config.wifiScanEvidenceWindow }).count >= config.wifiScanMinOverlaps else { return }
        inFlight = true; lastQuery = now
        let epoch = generation
        let snapshot = samples
        let config = self.config
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = runProcess("/usr/bin/log", ["show", "--last", "\(Int(ceil(config.wifiScanHistory)))s", "--style", "json",
                "--predicate", "process == 'airportd' AND (eventMessage CONTAINS 'SCAN request received' OR eventMessage CONTAINS 'Apple80211Scan:')"], timeout: config.wifiScanQueryTimeout)
            let scans = result.succeeded ? WiFiScanEvidence.scans(json: result.stdout, config: config) : []
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard self.generation == epoch else { return }
                self.scans = scans
                self.setWarning(WiFiScanEvidence.hasProblem(samples: snapshot, scans: scans, now: Date(), config: config))
                if !result.succeeded {
                    DiagLog.shared.warn("wifi-scans", "Scan evidence unavailable: \(result.summary)", throttleKey: "wifi-scan-log")
                }
            }
        }
    }
}
