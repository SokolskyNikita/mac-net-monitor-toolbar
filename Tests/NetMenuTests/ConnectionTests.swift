import Testing
@testable import NetMenu

@Suite struct ConnectionTests {
    let header = ",interface,state,packets_in,bytes_in,packets_out,bytes_out,\n"
    @Test func countsOnlyOpenSocketsUsingIntervalTrafficWithoutDoubleCountingProcesses() throws {
        let output = header + "Browser.123,,,999,9999,999,9999,\n" + header + """
        Browser.123,,,3,30,4,40,
        tcp4 10.0.0.1:1<->1.1.1.1.443,en0,Established,1,10,2,20,
        tcp6 local.1<->remote.443,en0,Established,0,0,0,0,
        udp4 local.2<->remote.443,en0,,2,20,0,0,
        udp4 local.3<->remote.443,en0,,0,0,2,20,
        tcp4 *:80<->*:*,en0,Listen,0,0,0,0,
        tcp4 local.4<->remote.443,en0,CloseWait,0,5,0,5,
        tcp4 local.5<->local.6,lo0,Established,0,5,0,5,
        udp4 *:*<->*:*,undefined,,0,0,0,0,
        """.replacingOccurrences(of: "undefined", with: "")
        #expect(ConnectionCounts.parse(output) == ConnectionCounts(open: 4, receiving: 2, sending: 2, processCounts: [123: 4], packetsReceived: 3, packetsSent: 4, processPackets: [123: PacketCounts(received: 3, sent: 4)]))
        let apps = try #require(AppBandwidthParser.parse(output))
        #expect(apps.count == 1)
        #expect(apps.first?.pid == 123)
        #expect(apps.first?.bytesIn == 30)
    }
    @Test func consumersGroupNamesAndUseTheSharedCoveragePolicy() {
        let counts = ConnectionCounts(apps: [
            .init(name: "Browser", sent: 35), .init(name: "browser", sent: 30),
            .init(name: "Editor", received: 20), .init(name: "Chat", received: 15)])
        let top = TopConnectionApps(counts)
        #expect(TopConnectionApps(ConnectionCounts(apps: [.init(name: "Idle", open: 100), .init(name: "Active", open: 1, sent: 10)])).apps.map(\.name) == ["Active"])
        #expect(top.apps.map(\.name) == ["Browser", "Editor"])
        #expect(top.title == "Top conn. consumers (~85%): Browser, Editor")
        let spread = ConnectionCounts(apps: (1...5).map { .init(name: "App \($0)", received: 20) })
        #expect(TopConnectionApps(spread).apps.count == 3)
        #expect(TopConnectionApps(spread).title.contains("~60%"))
        let unattributed = ConnectionCounts(apps: [.init(name: "Browser", sent: 30)], packetsSent: 100)
        #expect(TopConnectionApps(unattributed).title.contains("~30%"))
    }

    @Test func missingSamplesDoNotBecomeZeroAndStaleCountsExpire() {
        #expect(ConnectionCounts.parse(header) == nil)
        #expect(ConnectionCounts.parse(header + header) == ConnectionCounts())
        var display = ConnectionDisplay()
        display.record(ConnectionCounts(packetsReceived: 30, packetsSent: 20), at: 10)
        #expect(display.title(at: 20) == "Connections: 30 received · 20 sent packets / 10s")
        #expect(display.fresh(at: 26) == nil)
        display.record(nil, at: 27)
        #expect(display.title(at: 27) == "Connections: unavailable")
    }
}
