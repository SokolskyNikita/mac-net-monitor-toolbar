import Foundation

/// Explicit address-family checks prevent IPv6 fallback from hiding broken IPv4.
enum IPVersion: String, CaseIterable {
    case ipv4, ipv6
    var curlFlag: String { self == .ipv4 ? "--ipv4" : "--ipv6" }
}

struct IPWebsiteChecks {
    var ipv4: [String: Bool] = [:]
    var ipv6: [String: Bool] = [:]

    /// Per-site results across families. A family that reached one site does not fetch the
    /// others, so a site is only reported failed if a working family failed to reach it; a
    /// failure seen only by a family with no access says nothing about the site.
    var combined: [String: Bool] {
        let merged = ipv4.merging(ipv6, uniquingKeysWith: { $0 || $1 })
        let working = [ipv4, ipv6].filter { $0.values.contains(true) }
        guard !working.isEmpty else { return merged }
        return merged.filter { site, reached in reached || working.contains { $0[site] == false } }
    }

    func status(for family: IPVersion) -> InternetStatus {
        let checks = family == .ipv4 ? ipv4 : ipv6
        if checks.values.contains(true) { return .reachable }
        // A local helper failure must not turn a single failed destination into an outage.
        return Latency.InternetSite.allCases.allSatisfy { checks[$0.rawValue] == false }
            ? .unreachable : .unknown
    }

    mutating func record(_ check: Latency.InternetCheck, site: Latency.InternetSite, family: IPVersion) {
        let success: Bool
        switch check.outcome {
        case .ok: success = true
        case .failed: success = false
        case .unmeasured: return
        }
        if family == .ipv4 { ipv4[site.rawValue] = success }
        else { ipv6[site.rawValue] = success }
    }
}
