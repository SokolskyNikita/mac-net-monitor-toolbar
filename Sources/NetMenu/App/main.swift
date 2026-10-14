import AppKit

if let command = CLICommand.parse(arguments: Array(CommandLine.arguments.dropFirst())) {
    exit(CLI.run(command))
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
