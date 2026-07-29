import AppKit
import Foundation

if CommandLine.arguments.contains("--sample") {
    let c0 = readCounters(); Thread.sleep(forTimeInterval: 1); let c1 = readCounters()
    let (down, up) = deltaRates(old: c0, new: c1, dt: 1)
    var tls: Date? = nil
    let r = probeWAN(forceTLS: true, lastTLS: &tls, gateway: nil, doGW: false)
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
    let loss = r.total > 0 ? Double(r.failed + r.rejected) / Double(r.total) : 1.0
    let obj = buildSampleJSON(id: id, secs: 1, latMs: r.ms, latMin: r.ms, latMax: r.ms, latSrc: r.src,
                              gwMs: nil, loss: r.ms == nil ? 1.0 : loss, rejected: r.rejected,
                              down: down, up: up, downPeak: down, upPeak: up)
    if let line = jsonLine(obj) { print(line) }
    exit(0)
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
