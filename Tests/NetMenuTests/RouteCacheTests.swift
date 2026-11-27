import Foundation
import Testing
@testable import NetMenu

@Suite struct RouteCacheTests {
    /// A routing table the test controls, and a count of how often a helper would have run.
    private final class Fixture: @unchecked Sendable {
        var routes: Data? = Data([1])
        var asked = 0
        lazy var cache = RouteCache(lifetime: 300) { [unowned self] in self.routes }

        func route(_ iface: String = "en0") -> String? {
            cache.route { self.asked += 1; return ((iface, "10.0.0.1"), true) }.iface
        }
    }

    @Test func helpersRunOnceWhileDefaultRoutesAreUnchanged() {
        let f = Fixture()
        #expect(f.route() == "en0")
        #expect(f.route("en9") == "en0")
        #expect(f.asked == 1)
        // "No router" from a helper that ran properly is an answer like any other.
        #expect(f.cache.localRouter(key: "en0|en0") { f.asked += 1; return (nil, true) } == nil)
        #expect(f.cache.localRouter(key: "en0|en0") { f.asked += 1; return (LocalRouter(interface: "en0", address: "x"), true) } == nil)
        #expect(f.cache.ssid(interface: "en0") { f.asked += 1; return ("home", true) } == "home")
        #expect(f.cache.ssid(interface: "en0") { f.asked += 1; return ("other", true) } == "home")
        #expect(f.asked == 3)
    }

    @Test func changedRoutesInvalidationAndExpiryAskAgain() {
        let f = Fixture()
        _ = f.route()
        f.routes = Data([2])
        #expect(f.route("en5") == "en5")
        f.cache.invalidate()
        #expect(f.route("en6") == "en6")
        #expect(f.asked == 3)

        let expired = Fixture()
        expired.cache = RouteCache(lifetime: 0) { expired.routes }
        _ = expired.route(); _ = expired.route()
        #expect(expired.asked == 2)
    }

    @Test func unreadableOrMovingRoutesAreNeverReused() {
        let unreadable = Fixture()
        unreadable.routes = nil
        _ = unreadable.route(); _ = unreadable.route()
        #expect(unreadable.asked == 2)

        // The routes changed while the helper ran: its answer may describe either state.
        let moving = Fixture()
        #expect(moving.cache.route { moving.asked += 1; moving.routes = Data([2]); return (("en0", nil), true) }.iface == "en0")
        #expect(moving.route("en1") == "en1")
        #expect(moving.asked == 2)
    }

    @Test func aFailedHelperIsAskedAgainNextTime() {
        // A helper that timed out reports nothing, which must not stand in for the real answer.
        let f = Fixture()
        #expect(f.cache.route { f.asked += 1; return ((nil, nil), false) }.iface == nil)
        #expect(f.route() == "en0")
        #expect(f.cache.localRouter(key: "k") { f.asked += 1; return (nil, false) } == nil)
        #expect(f.cache.localRouter(key: "k") { f.asked += 1; return (LocalRouter(interface: "en0", address: "x"), true) } != nil)
        #expect(f.asked == 4)
    }

    @Test func networkNameExpiresSoonerThanTheRest() {
        let routes = Data([1])
        var asked = 0
        let cache = RouteCache(lifetime: 300, nameLifetime: 0) { routes }
        _ = cache.ssid(interface: "en0") { asked += 1; return ("home", true) }
        #expect(cache.ssid(interface: "en0") { asked += 1; return ("cafe", true) } == "cafe")
        _ = cache.route { asked += 1; return (("en0", nil), true) }
        _ = cache.route { asked += 1; return (("en9", nil), true) }
        #expect(asked == 3)
    }

    /// One routing message: a default route unless `host`, followed by its destination address.
    private func routeMessage(interface: UInt16, flags: Int32, used: Int32 = 0, lastByte: UInt8 = 0) -> Data {
        var destination = [UInt8](repeating: 0, count: 16)
        destination[0] = 16; destination[1] = UInt8(AF_INET); destination[7] = lastByte
        var header = rt_msghdr2()
        header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr2>.stride + destination.count)
        header.rtm_index = interface
        header.rtm_flags = flags
        header.rtm_addrs = RTA_DST
        header.rtm_use = used
        var bytes = withUnsafeBytes(of: &header) { Data($0) }
        bytes.append(Data(count: MemoryLayout<rt_msghdr2>.stride - MemoryLayout<rt_msghdr2>.size))
        bytes.append(contentsOf: destination)
        return bytes
    }

    private func key(_ dump: Data) -> Data { dump.withUnsafeBytes { RouteCache.defaultRoutes(in: $0) } }

    @Test func routeKeyCoversDefaultRoutesAndIgnoresCountersAndOtherRoutes() {
        let en0 = routeMessage(interface: 4, flags: RTF_UP | RTF_GATEWAY)
        #expect(!key(en0).isEmpty)
        // Traffic counters move with every packet; they must not look like a route change.
        #expect(key(routeMessage(interface: 4, flags: RTF_UP | RTF_GATEWAY, used: 99)) == key(en0))
        #expect(key(routeMessage(interface: 5, flags: RTF_UP | RTF_GATEWAY)) != key(en0))
        #expect(key(routeMessage(interface: 4, flags: RTF_UP)) != key(en0))
        // Host routes and routes to a real destination are not default routes.
        #expect(key(routeMessage(interface: 4, flags: RTF_UP | RTF_HOST)).isEmpty)
        #expect(key(routeMessage(interface: 4, flags: RTF_UP, lastByte: 1)).isEmpty)
        #expect(key(en0 + routeMessage(interface: 4, flags: RTF_UP | RTF_HOST)) == key(en0))
        // A cut-off record ends the read without touching memory past it.
        #expect(key(en0 + en0.dropLast(4)) == key(en0))
    }

    @Test @MainActor func healthBandsMatchWhatTheLogTreatsAsAChange() {
        #expect(AppDelegate.healthBand(100) == "95-100%")
        #expect(AppDelegate.healthBand(95) == "95-100%")
        #expect(AppDelegate.healthBand(94) == "90-94%")
        #expect(AppDelegate.healthBand(90) == "90-94%")
        #expect(AppDelegate.healthBand(87) == "80-89%")
        #expect(AppDelegate.healthBand(0) == "0-9%")
    }

    @Test func liveRoutingTableIsReadableAndStable() throws {
        // The system may change a route between two reads; it will not keep doing so.
        var stable = false
        for _ in 0..<5 where !stable {
            let first = try #require(RouteCache.defaultRoutes())
            stable = RouteCache.defaultRoutes() == first
        }
        #expect(stable)
    }

    @Test func curlOutputSplitsIntoBodyAndTrailer() {
        let reply = Latency.splitCurlOutput(Data("line one\nline two\n200 0.25".utf8), bodyLimit: 65536)
        #expect(reply.body == "line one\nline two")
        #expect(reply.trailer == "200 0.25")
        #expect(Latency.splitCurlOutput(Data("\n000".utf8), bodyLimit: 10).body.isEmpty)
        #expect(Latency.splitCurlOutput(Data("abcdef\n200".utf8), bodyLimit: 3).body == "abc")
        // As with the body files this replaced, text that is not UTF-8 reads as empty.
        #expect(Latency.splitCurlOutput(Data([0xff, 0xfe, 0x0a, 0x32, 0x30, 0x30]), bodyLimit: 10) == ("", "200"))
        #expect(Latency.splitCurlOutput(Data("200".utf8), bodyLimit: 10) == ("", "200"))
    }
}
