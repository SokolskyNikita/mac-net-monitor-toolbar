import Foundation
import Testing
@testable import NetMenu

@Suite struct AppBandwidthParserTests {
    @Test func parsesTheSecondDeltaBlockAndKeepsCommasInProcessNames() throws {
        let output = """
        ,bytes_in,bytes_out,
        Safari.101,900,250,
        Cloudflare, Warp.202,40,20,
        ,bytes_in,bytes_out,
        Safari.101,125,8,
        Cloudflare, Warp.202,17,6,
        ,bytes_in,bytes_out,
        Safari.101,999,999,
        """

        let rows = try #require(AppBandwidthParser.parse(output))
        #expect(rows == [
            NetTopProcessCounters(processName: "Safari", pid: 101, bytesIn: 125, bytesOut: 8),
            NetTopProcessCounters(processName: "Cloudflare, Warp", pid: 202, bytesIn: 17, bytesOut: 6),
        ])
    }

    @Test func parsesQuotedNamesAndTrailingDelimiters() throws {
        let output = """
        name,bytes_in,bytes_out,
        Baseline.1,999,999,
        name,bytes_in,bytes_out,
        "Mail, Inc. Helper.456",12,34,
        """

        let rows = try #require(AppBandwidthParser.parse(output))
        #expect(rows == [NetTopProcessCounters(processName: "Mail, Inc. Helper", pid: 456,
                                               bytesIn: 12, bytesOut: 34)])
    }

    @Test func repeatedHeaderOnlyBlocksRepresentAnIdleSample() throws {
        let output = """
        bytes_in,bytes_out,
        bytes_in,bytes_out,
        """
        #expect(try #require(AppBandwidthParser.parse(output)).isEmpty)
    }

    @Test func keepsValidRowsWhenOtherIntervalRowsAreMalformedOrUnattributable() throws {
        let output = """
        bytes_in,bytes_out,
        Baseline.1,900,250,
        bytes_in,bytes_out,
        Browser.10,20,4,
        ProcessWithoutPid,30,5,
        Broken.12,partial,3,
        """

        #expect(try #require(AppBandwidthParser.parse(output)) == [
            NetTopProcessCounters(processName: "Browser", pid: 10, bytesIn: 20, bytesOut: 4),
        ])
    }

    @Test func nonemptyIntervalWithNoParseableRowsIsUnavailable() {
        let output = """
        bytes_in,bytes_out,
        Baseline.1,900,250,
        bytes_in,bytes_out,
        ProcessWithoutPid,30,5,
        Broken.12,partial,3,
        """

        #expect(AppBandwidthParser.parse(output) == nil)
    }

    @Test func incompleteOrMalformedOutputIsUnavailable() {
        #expect(AppBandwidthParser.parse("bytes_in,bytes_out,\nBrowser.1,10,2,\n") == nil)
        #expect(AppBandwidthParser.parse("bytes_in,bytes_out,\nBrowser.1,10,2,\nbytes_in,bytes_out,\nBrowser.1,partial,2,\n") == nil)
        #expect(AppBandwidthParser.parse("bytes_in,bytes_out,\nBrowser.1,10,2,\nbytes_in,bytes_out,\nBrowser.1,10,\n") == nil)
    }
}

@Suite struct AppBandwidthGroupingTests {
    private func row(_ name: String, _ pid: Int32, _ down: UInt64, _ up: UInt64) -> NetTopProcessCounters {
        NetTopProcessCounters(processName: name, pid: pid, bytesIn: down, bytesOut: up)
    }

    @Test func nestedHelpersGroupUnderTheOutermostAppBundle() throws {
        let rows = [
            row("Codex", 41, 100, 25),
            row("Codex Service", 42, 50, 10),
        ]
        let paths: [Int32: String] = [
            41: "/Applications/Codex.app/Contents/MacOS/Codex",
            42: "/Applications/Codex.app/Contents/XPCServices/Helper.app/Contents/MacOS/Helper",
        ]
        let grouped = AppBandwidthProcessGrouper.aggregate(rows) { item in
            AppBandwidthProcessGrouper.identity(
                processName: item.processName,
                pid: item.pid,
                executablePath: paths[item.pid],
                runningApplicationName: item.pid == 42 ? "Codex Service" : "Codex"
            )
        }

        let app = try #require(grouped.first)
        #expect(grouped.count == 1)
        #expect(app.id == "app:/Applications/Codex.app")
        #expect(app.name == "Codex")
        #expect(app.downBytes == 150)
        #expect(app.upBytes == 35)
    }

    @Test func standaloneProcessesGroupByFullExecutableAndHaveReadableFallbackNames() throws {
        let rows = [row("configd", 50, 5, 3), row("configd", 51, 7, 4)]
        let grouped = AppBandwidthProcessGrouper.aggregate(rows) { item in
            AppBandwidthProcessGrouper.identity(
                processName: item.processName,
                pid: item.pid,
                executablePath: "/usr/libexec/configd"
            )
        }

        let process = try #require(grouped.first)
        #expect(grouped.count == 1)
        #expect(process.id == "exec:/usr/libexec/configd")
        #expect(process.name == "configd")
        #expect(process.downBytes == 12)
        #expect(process.upBytes == 7)
    }

    @Test func missingExecutablePathsFallBackToProcessNames() throws {
        let grouped = AppBandwidthProcessGrouper.aggregate([row("mdworker_shared", 70, 1, 2)]) { item in
            AppBandwidthProcessGrouper.identity(processName: item.processName, pid: item.pid, executablePath: nil)
        }
        #expect(try #require(grouped.first).name == "mdworker_shared")
        #expect(grouped.first?.id == "process:mdworker_shared:70")
    }
}
