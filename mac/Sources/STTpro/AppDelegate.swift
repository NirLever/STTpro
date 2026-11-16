import AppKit
import Combine
import ServiceManagement
import SwiftUI
import STTproCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = SettingsStore()
    private(set) var history: HistoryStore?
    private(set) var orchestrator: Orchestrator!
    let navigation = SettingsNavigation()

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private lazy var historyModel = HistoryModel(store: history)
    private var cancellables = Set<AnyCancellable>()

    // Hotkey IDs
    private enum HK { static let hold: UInt32 = 1, toggle: UInt32 = 2, pasteLast: UInt32 = 3, promptBase: UInt32 = 100 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            history = try HistoryStore(url: AppPaths.historyDatabase)
        } catch {
            Log.error("Could not open history database", error)
        }
        orchestrator = Orchestrator(store: store, history: history)
        orchestrator.openSettings = { [weak self] section in self?.showSettings(section: section) }

        Theme.apply(mode: store.settings.themeMode)
        NSApp.mainMenu = Self.makeMainMenu()
        setUpStatusItem()
        registerHotkeys()

        // Re-register hotkeys when any binding / prompt changes.
        store.$settings
            .map { s in [s.holdToTalkHotkey, s.toggleRecordingHotkey, s.pasteLastTranscriptHotkey]
                + s.enabledPromptBindings.compactMap(\.hotkey) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.registerHotkeys() } }
            .store(in: &cancellables)

        orchestrator.$state
            .sink { [weak self] state in self?.updateStatusIcon(state) }
            .store(in: &cancellables)

        Log.info("STTpro started (\(Bundle.main.bundleIdentifier ?? "unbundled"))")
        runFirstLaunchChecks()
    }

    // MARK: - First run

    private func runFirstLaunchChecks() {
        let s = store.settings
        if !s.hasCompletedOnboarding {
            store.settings.hasCompletedOnboarding = true
            showSettings(section: .setup)
        } else if !Permissions.microphoneGranted || !Permissions.accessibilityGranted || store.sttKeyMissing
                    || SystemShortcutConflicts.conflict(for: s.holdToTalkHotkey) != nil {
            showSettings(section: .setup)
        }
    }

    // MARK: - Hotkeys

    func registerHotkeys() {
        let hk = HotkeyManager.shared
        hk.unregisterAll()
        let s = store.settings
        let o = orchestrator!
        hk.register(id: HK.hold, binding: s.holdToTalkHotkey,
                    onPress: { o.holdPressed() }, onRelease: { o.holdReleased() })
        hk.register(id: HK.toggle, binding: s.toggleRecordingHotkey, onPress: { o.togglePressed() })
        hk.register(id: HK.pasteLast, binding: s.pasteLastTranscriptHotkey, onPress: { o.pasteLast() })
        for (i, entry) in s.enabledPromptBindings.enumerated() {
            guard let binding = entry.hotkey else { continue }
            hk.register(id: HK.promptBase + UInt32(i), binding: binding,
                        onPress: { o.promptPressed(i) }, onRelease: { o.promptReleased(i) })
        }
        navigation.failedHotkeys = hk.failed
    }

    // MARK: - Main menu

    /// A menu-bar (LSUIElement) app shows no main menu, but text fields still
    /// need one: ⌘V/⌘C/⌘X/⌘A/⌘Z are delivered as menu key equivalents. Without
    /// this, pasting an API key into Settings silently does nothing.
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "STTpro")
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit STTpro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        return main
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon(.idle)
    }

    private func updateStatusIcon(_ state: Orchestrator.State) {
        guard let button = statusItem?.button else { return }
        let symbol: String
        switch state {
        case .idle: symbol = "mic"
        case .recording: symbol = "mic.fill"
        case .transcribing, .postProcessing: symbol = "ellipsis.circle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "STTpro")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = state == .recording ? .systemRed : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = store.settings
        let state = orchestrator.state

        let header = NSMenuItem(title: statusText(state), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let hint = NSMenuItem(title: "Hold \(s.holdToTalkHotkey.displayName) to dictate", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        if !Permissions.microphoneGranted || !Permissions.accessibilityGranted || store.sttKeyMissing {
            menu.addItem(item("⚠︎ Finish setup…", #selector(openSetup)))
            menu.addItem(.separator())
        }

        menu.addItem(item(state == .recording ? "Stop Recording" : "Start Recording", #selector(toggleRecording)))
        if state == .recording { menu.addItem(item("Cancel Recording", #selector(cancelRecording))) }
        menu.addItem(item("Paste Last Transcript", #selector(pasteLast)))
        menu.addItem(.separator())
        menu.addItem(item("History…", #selector(openHistory)))
        menu.addItem(item("Settings…", #selector(openSettingsMenu), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit STTpro", #selector(quit), key: "q"))
    }

    private func statusText(_ state: Orchestrator.State) -> String {
        switch state {
        case .idle: return "STTpro — Ready"
        case .recording: return "STTpro — Recording…"
        case .transcribing: return "STTpro — Transcribing…"
        case .postProcessing: return "STTpro — Processing…"
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleRecording() { orchestrator.toggleFromMenu() }
    @objc private func cancelRecording() { orchestrator.cancelRecording() }
    @objc private func pasteLast() { orchestrator.pasteLast() }
    @objc private func openHistory() { showHistoryWindow() }
    @objc private func openSettingsMenu() { showSettings(section: nil) }
    @objc private func openSetup() { showSettings(section: .setup) }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Settings window

    func showSettings(section: SettingsSection?) {
        navigation.tab = .settings
        if settingsWindow == nil {
            let root = MainWindowView()
                .environmentObject(store)
                .environmentObject(navigation)
                .environmentObject(historyModel)
            settingsWindow = makeWindow(title: "STTpro", autosave: "STTproSettings",
                                        size: NSSize(width: 560, height: 760), min: NSSize(width: 480, height: 520),
                                        content: NSHostingView(rootView: root))
        }
        navigation.scrollTarget = section
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Separate "Transcript History" window (HistoryWindow.xaml).
    func showHistoryWindow() {
        if historyWindow == nil {
            let root = HistoryPage(showsTitle: true).environmentObject(historyModel)
            historyWindow = makeWindow(title: "STTpro - Transcript History", autosave: "STTproHistory",
                                       size: NSSize(width: 680, height: 580), min: NSSize(width: 480, height: 400),
                                       content: NSHostingView(rootView: root))
        }
        historyModel.reload()
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(title: String, autosave: String, size: NSSize, min: NSSize, content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.minSize = min
        window.setFrameAutosaveName(autosave)
        if !window.setFrameUsingName(autosave) {
            window.setContentSize(size)
            window.center()
        }
        return window
    }
}
