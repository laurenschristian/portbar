import AppKit

// One binary: invoked as `portbar` (the CLI symlink) or with arguments it is the CLI, otherwise the menu bar app.
let argv = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") && !$0.hasPrefix("-NS") }
if (CommandLine.arguments[0] as NSString).lastPathComponent == "portbar" || !argv.isEmpty {
    exit(CLI.run(argv))
}

let app = NSApplication.shared
let delegate = PortBar()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
