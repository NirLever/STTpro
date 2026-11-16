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
        orchestrator.openSettings = { [weak self] tab in self?.showSettings(tab: tab) }

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
            showSettings(tab: .welcome)
            return
        }
        if !Permissions.microphoneGranted || !Permissions.accessibilityGranted {
            showSettings(tab: .permissions)
        } else if store.sttKeyMissing {
            showSettings(tab: .providers)
        } else if SystemShortcutConflicts.conflict(for: s.holdToTalkHotkey) != nil {
            showSettings(tab: .general)
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
    @objc private func openHistory() { showSettings(tab: .history) }
    @objc private func openSettingsMenu() { showSettings(tab: navigation.tab == .welcome ? .general : navigation.tab) }
    @objc private func openSetup() {
        showSettings(tab: (!Permissions.microphoneGranted || !Permissions.accessibilityGranted) ? .permissions : .providers)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Settings window

    func showSettings(tab: SettingsTab) {
        navigation.tab = tab
        if settingsWindow == nil {
            let root = SettingsView()
                .environmentObject(store)
                .environmentObject(navigation)
                .environmentObject(HistoryModel(store: history))
                .environment(\.reregisterHotkeys, { [weak self] in self?.registerHotkeys() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "STTpro Settings"
            window.contentView = NSHostingView(rootView: root)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("STTproSettings")
            if !window.setFrameUsingName("STTproSettings") { window.center() }
            window.minSize = NSSize(width: 640, height: 480)
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Which settings tab is shown, plus hotkey registration problems to surface.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .general
    @Published var failedHotkeys: [HotkeyBinding] = []
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case welcome, general, providers, prompts, history, permissions, usage
    var id: String { rawValue }
    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .general: return "General"
        case .providers: return "Providers"
        case .prompts: return "Smart Prompts"
        case .history: return "History"
        case .permissions: return "Permissions"
        case .usage: return "Usage"
        }
    }
    var symbol: String {
        switch self {
        case .welcome: return "hand.wave"
        case .general: return "gearshape"
        case .providers: return "network"
        case .prompts: return "sparkles"
        case .history: return "clock.arrow.circlepath"
        case .permissions: return "lock.shield"
        case .usage: return "chart.bar"
        }
    }
}

private struct ReregisterHotkeysKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var reregisterHotkeys: () -> Void {
        get { self[ReregisterHotkeysKey.self] }
        set { self[ReregisterHotkeysKey.self] = newValue }
    }
}
