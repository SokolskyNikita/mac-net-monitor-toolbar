import Darwin
import Foundation
import Testing
@testable import NetMenu

private func routeInterfaceMessage(index: UInt16, rx: UInt64, tx: UInt64) -> Data {
    var header = if_msghdr2()
    header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
    header.ifm_type = UInt8(RTM_IFINFO2)
    header.ifm_index = index
    header.ifm_data.ifi_ibytes = rx
    header.ifm_data.ifi_obytes = tx
    return withUnsafeBytes(of: &header) { Data($0) }
}

/// A record as the kernel writes it: the header followed by a link-level address holding the name.
private func namedRouteInterfaceMessage(index: UInt16, name: String, rx: UInt64, tx: UInt64) -> Data {
    let nameBytes = Array(name.utf8)
    var link: [UInt8] = [UInt8(8 + nameBytes.count), UInt8(AF_LINK)]
    withUnsafeBytes(of: index) { link.append(contentsOf: $0) }
    link += [0, UInt8(nameBytes.count), 0, 0] + nameBytes
    var header = if_msghdr2()
    header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.stride + link.count)
    header.ifm_type = UInt8(RTM_IFINFO2)
    header.ifm_index = index
    header.ifm_addrs = RTA_IFP
    header.ifm_data.ifi_ibytes = rx
    header.ifm_data.ifi_obytes = tx
    var bytes = withUnsafeBytes(of: &header) { Data($0) }
    bytes.append(Data(count: MemoryLayout<if_msghdr2>.stride - MemoryLayout<if_msghdr2>.size))
    bytes.append(contentsOf: link)
    return bytes
}

private func shortRouteMessage(type: UInt8) -> Data {
    var length = UInt16(4)
    var bytes = withUnsafeBytes(of: &length) { Data($0) }
    bytes.append(contentsOf: [0, type])
    return bytes
}

@Suite struct BandwidthCounterReaderTests {
    @Test func reads64BitCountersForEthernetNamesOnly() {
        let largeRX: UInt64 = (1 << 40) + 123
        let largeTX: UInt64 = (1 << 48) + 456
        var dump = routeInterfaceMessage(index: 4, rx: largeRX, tx: largeTX)
        dump.append(routeInterfaceMessage(index: 5, rx: 100, tx: 200))
        dump.append(routeInterfaceMessage(index: 6, rx: 300, tx: 400))

        let counters = BandwidthCounterReader.parseRouteDump(
            dump,
            interfaceNames: [4: "en0", 5: "awdl0"]
        )

        #expect(counters.rx == ["en0": largeRX])
        #expect(counters.tx == ["en0": largeTX])
    }

    @Test func readsNamesEmbeddedInRecordsWithoutLookingThemUp() {
        var dump = namedRouteInterfaceMessage(index: 4, name: "en0", rx: 11, tx: 12)
        dump.append(namedRouteInterfaceMessage(index: 5, name: "utun3", rx: 21, tx: 22))
        dump.append(namedRouteInterfaceMessage(index: 6, name: "en12", rx: 31, tx: 32))
        var lookups = 0

        let counters = BandwidthCounterReader.parseRouteDump(dump) { _ in lookups += 1; return "en9" }

        #expect(counters.rx == ["en0": 11, "en12": 31])
        #expect(counters.tx == ["en0": 12, "en12": 32])
        #expect(lookups == 0)
    }

    @Test func liveDumpNamesMatchTheSystemInterfaceList() throws {
        var expected: Set<String> = []
        let list = try #require(if_nameindex())
        defer { if_freenameindex(list) }
        var entry = list
        while entry.pointee.if_index != 0 {
            let name = String(cString: entry.pointee.if_name)
            if name.hasPrefix("en") { expected.insert(name) }
            entry += 1
        }
        let dump = try #require(BandwidthCounterReader.routeDump())
        var lookups = 0

        let counters = BandwidthCounterReader.parseRouteDump(dump) { _ in lookups += 1; return nil }

        #expect(Set(counters.rx.keys) == expected)
        #expect(lookups == 0)
    }

    @Test func skipsShortOtherMessagesAndContinuesAtNextRecord() {
        var dump = shortRouteMessage(type: UInt8(RTM_NEWADDR))
        dump.append(routeInterfaceMessage(index: 8, rx: 9, tx: 10))

        let counters = BandwidthCounterReader.parseRouteDump(dump, interfaceNames: [8: "en1"])

        #expect(counters.rx == ["en1": 9])
        #expect(counters.tx == ["en1": 10])
    }

    @Test func stopsSafelyAtTruncatedOrMalformedRecord() {
        let complete = routeInterfaceMessage(index: 8, rx: 9, tx: 10)
        let truncated = Data(complete.dropLast())
        let malformed = Data([0, 0, 0, UInt8(RTM_IFINFO2)])

        #expect(BandwidthCounterReader.parseRouteDump(truncated, interfaceNames: [8: "en1"]).rx.isEmpty)
        #expect(BandwidthCounterReader.parseRouteDump(malformed, interfaceNames: [8: "en1"]).rx.isEmpty)
    }
}
