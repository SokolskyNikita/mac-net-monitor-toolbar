import Foundation

/// CLI selection is independent of AppKit startup and does not perform any I/O.
enum CLICommand: Equatable {
    case sample
    case localSample
    case localProbe
    case speedTest(lowData: Bool)

    private enum Flag: String {
        case sample = "--sample"
        case localSample = "--local-sample"
        case localProbe = "--local-probe"
        case speedTest = "--speedtest"
        case lowData = "--low-data"
    }

    /// Arguments exclude the executable name. Preserve the existing precedence when multiple
    /// commands are supplied: sample, local probe, local sample, speed test. Other arguments are
    /// ignored; without a recognized command the app starts its GUI. Low Data Mode applies only to speed tests.
    static func parse(arguments: [String]) -> Self? {
        let flags = Set(arguments.compactMap(Flag.init(rawValue:)))
        if flags.contains(.sample) { return .sample }
        if flags.contains(.localProbe) { return .localProbe }
        if flags.contains(.localSample) { return .localSample }
        if flags.contains(.speedTest) { return .speedTest(lowData: flags.contains(.lowData)) }
        return nil
    }
}

/// Executes diagnostics using the same measurement services as the menu-bar app.
/// Returns the process exit code; only main.swift terminates the process.
enum CLI {
    private static let localSampleCount = 20

    static func run(_ command: CLICommand) -> Int32 {
        switch command {
        case .sample: return sample()
        case .localSample: return local(probeAllProtocols: false)
        case .localProbe: return local(probeAllProtocols: true)
        case .speedTest(let lowData): return speedTest(lowData: lowData)
        }
    }

    private static func sample() -> Int32 {
        let bandwidth = measureBandwidth()
        let down = bandwidth.rates.down, up = bandwidth.rates.up
        let r = Latency.measure(gateway: nil)
        let id = resolveIdentitySample()
        let latStr = r.ms.map { String(format: "%.1f", $0) } ?? "nan"
        let netName = id.network ?? "none"
        let netJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: [netName]),
           let s = String(data: data, encoding: .utf8) {
            netJSON = String(s.dropFirst().dropLast())
        } else {
            netJSON = "\"\(netName)\""
        }
        let downI = UInt64(finiteNonNeg(down, max: 1e13)?.rounded() ?? 0)
        let upI = UInt64(finiteNonNeg(up, max: 1e13)?.rounded() ?? 0)
        print("latency_ms=\(latStr) down_Bps=\(downI) up_Bps=\(upI) type=\(id.type) network=\(netJSON)")
        print("probe: \(r.logLine)")
        let loss = r.total > 0 ? Double(r.failed + r.rejected) / Double(r.total) : 1.0
        let obj = buildSampleJSON(id: id, secs: bandwidth.seconds, latMs: r.ms, latMin: r.ms, latMax: r.ms, latSrc: r.source?.rawValue,
                                  gwMs: nil, loss: r.ms == nil ? 1.0 : loss, rejected: r.rejected,
                                  down: down, up: up, downPeak: down, upPeak: up,
                                  health: r.internetReachable ? nil : 0,
                                  internetChecks: r.internetChecks, captive: r.captive)
        if let line = jsonLine(obj) { print(line) }
        return 0
    }

    private static func local(probeAllProtocols: Bool) -> Int32 {
        func router() -> LocalRouter? {
            resolveLocalRouter(preferred: parseRoute().iface, ports: hardwarePorts())
        }
        guard let target = router() else {
            print(LocalHealthTracker().menuTitle(router: nil, report: nil)); return 1
        }
        if probeAllProtocols {
            print("Router: \(target.address) on \(target.interface)")
            for method in LocalProbeMethod.allCases {
                switch LocalProtocols.probe(method, target) {
                case .reply(let r): print(String(format: "%@: %.2fms", method.label, r.ms))
                case .lost: print("\(method.label): no reply")
                case .unmeasured(let why): print("\(method.label): unavailable (\(why))")
                }
            }
            return 0
        }
        let session = LocalProbeSession()
        print("Router: \(target.address) on \(target.interface); \(localSampleCount) probes, \(String(format: "%g", Configuration.monitoring.probeInterval)) seconds apart")
        var tracker = LocalHealthTracker()
        var i = 0
        while i < localSampleCount {
            let start = HealthTracker.now()
            guard let result = session.poll(target) else {
                Thread.sleep(forTimeInterval: Configuration.monitoring.localConfirmationInterval)
                continue
            }
            tracker.record(result.outcome, method: result.method)
            print("method: \(result.method.label)")
            switch result.outcome {
            case .reply(let reply): print(String(format: "probe %d: %.2fms", i + 1, reply.ms))
            case .lost: print("probe \(i + 1): no reply")
            case .unmeasured(let why): print("probe \(i + 1): unavailable (\(why))")
            }
            i += 1
            if i < localSampleCount {
                Thread.sleep(forTimeInterval: max(0, Configuration.monitoring.localConfirmationInterval - (HealthTracker.now() - start)))
            }
        }
        guard router() == target else { print("Local network changed; result discarded"); return 1 }
        print(tracker.menuTitle(router: target.address, report: tracker.report()))
        return 0
    }

    private static func speedTest(lowData: Bool) -> Int32 {
        // Same engine as the menu, without the UI. `--low-data` uses the smaller budget.
        let config = lowData ? SpeedTestConfig.lowData : SpeedTestConfig.standard
        var last = ""
        let result = SpeedTest.run(config: config, lowData: config.budgetBytes == SpeedTestConfig.lowDataBudget,
                                   makeTransport: { URLSessionSpeedTransport() }, progress: { p in
            let line: String
            switch p {
            case .latency: line = "measuring latency"
            case .transfer(let d, let mbps): line = "\(d.rawValue) " + (mbps.map { String(format: "%.1f Mbps", $0) } ?? "starting")
            }
            if line != last { print(line); last = line }
        })
        print(result.title)
        print(result.detail)
        return result.status == .failed ? 1 : 0
    }
}
