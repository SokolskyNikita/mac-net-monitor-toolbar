import Foundation

// JSON event schemas shared by the GUI and command-line entry points.

func buildSampleJSON(id: Identity, secs: Double, latMs: Double?, latMin: Double?, latMax: Double?, latSrc: String?,
                     gwMs: Double?, loss: Double, rejected: Int, down: Double, up: Double, downPeak: Double, upPeak: Double,
                     health: Int? = nil, internetChecks: [String: Bool]? = nil, captive: Bool? = nil, localHealth: HealthReport? = nil, localMethod: LocalProbeMethod? = nil) -> [String: Any] {
    func n(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }
    func i(_ v: Int?) -> Any { v.map { $0 as Any } ?? NSNull() }
    func s(_ v: String?) -> Any { v.map { $0 as Any } ?? NSNull() }
    return [
        "ts": isoTimestamp(), "event": "sample", "secs": secs,
        "if": s(id.iface), "type": id.type, "network": s(id.network), "bssid": s(id.bssid), "router": s(id.router),
        "lat_ms": n(latMs), "lat_min": n(latMin), "lat_max": n(latMax), "lat_src": s(latSrc),
        "local_router": s(id.localRouter?.address), "local_interface": s(id.localRouter?.interface),
        "local_method": s(localMethod?.rawValue),
        "local_health": i(localHealth?.score), "local_loss": n(localHealth?.loss),
        "local_jitter_ms": n(localHealth?.jitterMs), "local_latency_ms": n(localHealth?.latencyMs),
        "gw_ms": n(gwMs), "loss": loss, "rejected": rejected, "health": i(health),
        "internet_checks": internetChecks.map { $0 as Any } ?? NSNull(),
        "internet_reachable": internetChecks.map { $0.values.contains(true) as Any } ?? NSNull(),
        "captive": captive.map { $0 as Any } ?? NSNull(),
        "rssi": i(id.rssi), "noise": i(id.noise), "tx_rate_mbps": n(id.txRate), "channel": i(id.channel),
        "down_Bps": down, "up_Bps": up, "down_peak_Bps": downPeak, "up_peak_Bps": upPeak
    ]
}

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
}()
private let isoLock = NSLock()

func isoTimestamp(_ date: Date = Date()) -> String {
    isoLock.lock(); defer { isoLock.unlock() }
    return isoFormatter.string(from: date)
}

func jsonLine(_ obj: [String: Any]) -> String? {
    guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return nil }
    return s
}

/// End-of-window diagnostic snapshot. UI filtering never removes evidence from the log.
struct HealthStatsSnapshot {
    var report: HealthReport?
    var transport: HealthReport?
    var local: HealthReport?
    var reconnects5m: Int
    var recentTrouble: [String]
    var webChecksFresh: Bool
    var config: HealthConfig = Configuration.health
    var monitoring: MonitoringConfig = Configuration.monitoring

    var json: [String: Any] {
        func number<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
        return [
            "health_raw": number(report?.score),
            "health_loss": number(report?.loss),
            "health_jitter_ms": number(report?.jitterMs),
            "health_latency_ms": number(report?.latencyMs),
            "health_internet_reachable": number(report?.internetReachable),
            "health_websites_failing": number(report?.websitesFailing),
            "transport_health": number(transport?.score),
            "local_health_raw": number(local?.score),
            "health_window_s": config.window,
            "health_model": config.model,
            "health_weighting": "exponential_age",
            "health_weight_half_life_s": config.recencyHalfLife,
            "reconnects_5m": reconnects5m,
            "reconnect_window_s": monitoring.reconnectWindow,
            "recent_trouble": recentTrouble,
            "internet_checks_fresh": webChecksFresh
        ]
    }
}

/// Completed speed-test event, independent of menu actions and file storage.
struct SpeedTestStatsSnapshot {
    var result: SpeedTestResult
    var identity: Identity

    var json: [String: Any] {
        func phase(_ p: SpeedPhaseResult?, _ key: String) -> [String: Any] {
            [
                "\(key)_mbps": p?.mbps.map { $0 as Any } ?? NSNull(),
                "\(key)_bytes": p?.bytes ?? 0,
                "\(key)_streams": p?.streams ?? 0,
                "\(key)_stable": p?.stable ?? false,
                "\(key)_lower_bound": p?.budgetLimited ?? false,
                "\(key)_loaded_latency_ms": p?.loadedLatencyMs.map { $0 as Any } ?? NSNull()
            ]
        }
        var obj: [String: Any] = [
            "ts": isoTimestamp(), "event": "speedtest", "status": result.status.rawValue,
            "type": identity.type, "network": identity.network as Any? ?? NSNull(),
            "idle_latency_ms": result.idleLatencyMs.map { $0 as Any } ?? NSNull(),
            "errors": result.errors, "bytes_reserved": result.bytesReserved,
            "budget_bytes": result.budgetBytes, "low_data": result.lowData,
            "duration_s": result.elapsed, "server": Host.speedTest
        ]
        obj.merge(phase(result.download, "down")) { $1 }
        obj.merge(phase(result.upload, "up")) { $1 }
        return obj
    }
}
