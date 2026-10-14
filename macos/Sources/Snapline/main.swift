import AppKit

let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "--snapshot" {
    let code = MainActor.assumeIsolated {
        Snapshot.run(output: arguments[2], images: Array(arguments.dropFirst(3)))
    }
    exit(code)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    #if DEBUG
    UIDiagnostics.start(delegate: delegate)
    #endif
    withExtendedLifetime(delegate) { app.run() }
}
