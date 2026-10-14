import Testing
@testable import NetMenu

@Suite struct CLITests {
    @Test func selectsEachDiagnosticCommand() {
        #expect(CLICommand.parse(arguments: ["--sample"]) == .sample)
        #expect(CLICommand.parse(arguments: ["--local-sample"]) == .localSample)
        #expect(CLICommand.parse(arguments: ["--local-probe"]) == .localProbe)
        #expect(CLICommand.parse(arguments: ["--speedtest"]) == .speedTest(lowData: false))
    }

    @Test func lowDataAppliesToSpeedTestsRegardlessOfArgumentOrder() {
        for arguments in [["--speedtest", "--low-data"], ["--low-data", "--speedtest"],
                          ["--speedtest", "--low-data", "--speedtest", "--low-data"]] {
            #expect(CLICommand.parse(arguments: arguments) == .speedTest(lowData: true))
        }
        #expect(CLICommand.parse(arguments: ["--low-data", "--sample"]) == .sample)
        #expect(CLICommand.parse(arguments: ["--local-probe", "--low-data"]) == .localProbe)
    }

    @Test func conflictingCommandsKeepExistingPrecedence() {
        let cases: [([String], CLICommand)] = [
            (["--sample", "--local-probe", "--local-sample", "--speedtest"], .sample),
            (["--local-probe", "--local-sample", "--speedtest"], .localProbe),
            (["--local-sample", "--speedtest", "--low-data"], .localSample)
        ]
        for (arguments, expected) in cases {
            #expect(CLICommand.parse(arguments: arguments) == expected)
            #expect(CLICommand.parse(arguments: arguments.reversed()) == expected)
        }
    }

    @Test func absentCommandsAndUnrecognizedArgumentsPreserveGUIFallback() {
        for arguments in [[], ["--low-data"], ["--unknown"], ["--sample=value"], ["--SAMPLE"]] {
            #expect(CLICommand.parse(arguments: arguments) == nil)
        }
        #expect(CLICommand.parse(arguments: ["--unknown", "--sample", "--sample"]) == .sample)
    }
}
