import AppKit
import Foundation

if CommandLine.arguments.contains("--sample") {
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
    exit(0)
}

if CommandLine.arguments.contains("--speedtest") {
    // Same engine as the menu, without the UI. `--low-data` uses the smaller budget.
    let config = CommandLine.arguments.contains("--low-data") ? SpeedTestConfig.lowData : SpeedTestConfig.standard
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
    exit(result.status == "failed" ? 1 : 0)
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
