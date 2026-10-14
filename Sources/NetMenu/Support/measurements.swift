import Foundation

func finiteNonNeg(_ x: Double, max: Double = 600_000) -> Double? {
    guard x.isFinite, x >= 0, x <= max else { return nil }
    return x
}

func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted(); let n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

/// Append one sample. A source change drops the previous window so an ICMP reply and a
/// connect-timer fallback cannot be averaged into an RTT no probe returned.
func pushLatency(_ ms: Double, src: String?, into samples: inout [Double], source: inout String?, limit: Int) {
    if src != source {
        samples.removeAll(keepingCapacity: true)
        source = src
    }
    samples.append(ms)
    if samples.count > limit { samples.removeFirst(samples.count - limit) }
}
