import Darwin
import Testing
@testable import NetMenu

@Suite struct ProcessAttributionTests {
    @Test func followsShellsAndKeepsDifferentCallersSeparate() {
        var history = ProcessAncestry()
        history.record(pid: 10, entry: .init(parent: 1, started: 10, path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"))
        history.record(pid: 11, entry: .init(parent: 10, started: 11, path: "/bin/zsh"))
        history.record(pid: 12, entry: .init(parent: 11, started: 12, path: "/usr/bin/curl"))
        history.record(pid: 20, entry: .init(parent: 1, started: 10, path: "/Applications/Terminal.app/Contents/MacOS/Terminal"))
        history.record(pid: 21, entry: .init(parent: 20, started: 11, path: "/usr/bin/curl"))
        #expect(history.identity(processName: "curl", pid: 12).id == "app:/Applications/ChatGPT.app")
        #expect(history.identity(processName: "curl", pid: 21).id == "app:/Applications/Terminal.app")
        // Reparenting after exit must not erase a parent observed in this window.
        history.record(pid: 12, entry: .init(parent: 1, started: 12, path: nil))
        #expect(history.identity(processName: "curl", pid: 12).id == "app:/Applications/ChatGPT.app")
    }

    @Test func stopsAtNearestAppAndDoesNotAttributeToLauncher() {
        var history = ProcessAncestry()
        history.record(pid: 10, entry: .init(parent: 1, started: 10, path: "/Applications/Terminal.app/Contents/MacOS/Terminal"))
        history.record(pid: 11, entry: .init(parent: 10, started: 11, path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"))
        #expect(history.identity(processName: "ChatGPT", pid: 11).id == "app:/Applications/ChatGPT.app")
    }

    @Test func missingParentsCyclesAndReusedPIDsFallBack() {
        var history = ProcessAncestry()
        history.record(pid: 10, entry: .init(parent: 11, started: 10, path: "/usr/bin/curl"))
        #expect(history.identity(processName: "curl", pid: 10).id == "exec:/usr/bin/curl")
        history.record(pid: 11, entry: .init(parent: 10, started: 10, path: "/bin/zsh"))
        #expect(history.identity(processName: "curl", pid: 10).id == "exec:/usr/bin/curl")
        history.record(pid: 11, entry: .init(parent: 1, started: 12, path: "/Applications/Other.app/Contents/MacOS/Other"))
        #expect(history.identity(processName: "curl", pid: 10).id == "exec:/usr/bin/curl")
        #expect(history.identity(processName: "zsh", pid: 11).id == "process:zsh:11")
    }

    @Test func liveCaptureFindsThisProcess() {
        var history = ProcessAncestry()
        history.capture()
        #expect(history.entries[getpid()]?.parent == getppid())
        #expect(history.entries[getpid()]?.path != nil)
    }

    @Test func connectionRankingUsesCallerIdentityDespiteEqualNames() {
        let counts = ConnectionCounts(apps: [
            .init(id: "a", name: "Chrome", sent: 30),
            .init(id: "a", name: "Chrome", sent: 20),
            .init(id: "b", name: "Chrome", sent: 30),
            .init(id: "c", name: "Other", sent: 20),
        ])
        let top = TopConnectionApps(counts)
        #expect(top.apps.map(\.id) == ["a", "b"])
        #expect(top.apps.map(\.packets) == [50, 30])
    }

    @Test func aliasesRequireRecognizedBundleIdentity() {
        #expect(AppMenuNames.shortName(bundleID: "com.google.Chrome", fallback: "Google Chrome") == "Chrome")
        #expect(AppMenuNames.shortName(bundleID: "com.microsoft.VSCode", fallback: "Visual Studio Code") == "VS Code")
        #expect(AppMenuNames.shortName(bundleID: "us.zoom.xos", fallback: "zoom.us") == "Zoom")
        #expect(AppMenuNames.shortName(bundleID: nil, fallback: "Google Chrome") == "Google Chrome")
        #expect(AppMenuNames.shortName(bundleID: "custom.app", fallback: "Claude Code") == "Claude Code")
    }
}
