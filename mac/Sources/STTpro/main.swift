import AppKit

// Menu-bar only (LSUIElement in Info.plist); no Dock icon.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    if Snapshot.runIfRequested() { exit(0) }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
