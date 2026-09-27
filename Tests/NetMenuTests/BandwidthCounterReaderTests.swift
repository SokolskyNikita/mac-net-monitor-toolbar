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
