import AppKit
import SwiftUI
import STTproCore

/// Developer aid: `STTpro --snapshot <dir>` renders the main screens offscreen
/// to PNGs in light and dark (sample history, no API calls), then exits.
/// Used to compare against docs/screenshot-*.png without screen recording.
@MainActor
enum Snapshot {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = SettingsStore(inMemory: true)
        let nav = SettingsNavigation()
        let tmpDB = FileManager.default.temporaryDirectory.appendingPathComponent("sttpro-snapshot-\(UUID()).db")
        let history = try? HistoryStore(url: tmpDB)
        history?.save(TranscriptRecord(text: "Hello, this is a quick test of dictation on the Mac.", detectedLanguage: "english",
                                       durationSeconds: 3.4, providerName: "openai", insertionSucceeded: true, targetWindowName: "TextEdit"))
        history?.save(TranscriptRecord(text: "שלום, זו בדיקה של הכתבה בעברית.", detectedLanguage: "hebrew", durationSeconds: 2.1,
                                       providerName: "openai", insertionSucceeded: true, targetWindowName: "Notes",
                                       promptName: "Organize", originalText: "שלום זו בדיקה של הכתבה בעברית"))
        let historyModel = HistoryModel(store: history)

        let pill = PillModel()
        pill.phase = .recording(prompt: "Summarize")
        pill.elapsed = "0:07"
        pill.bars = [4, 8, 13, 18, 21, 19, 15, 10, 6, 4]

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            render(MainWindowView().environmentObject(store).environmentObject(nav).environmentObject(historyModel),
                   size: NSSize(width: 560, height: 2600), appearance: appearance, to: dir.appendingPathComponent("settings-\(name).png"))
            nav.tab = .history
            render(MainWindowView().environmentObject(store).environmentObject(nav).environmentObject(historyModel),
                   size: NSSize(width: 560, height: 640), appearance: appearance, to: dir.appendingPathComponent("history-\(name).png"))
            nav.tab = .settings
            render(PillView(model: pill), size: NSHostingView(rootView: PillView(model: pill)).fittingSize, appearance: appearance,
                   to: dir.appendingPathComponent("pill-\(name).png"))
        }
        try? FileManager.default.removeItem(at: tmpDB)
        return true
    }

    private static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
