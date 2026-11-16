import AVFoundation
import Combine
import SwiftUI
import ServiceManagement
import STTproCore

struct SettingsView: View {
    @EnvironmentObject var nav: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding(get: { nav.tab }, set: { if let t = $0 { nav.tab = t } })) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            Group {
                switch nav.tab {
                case .welcome: WelcomeView()
                case .general: GeneralSettingsView()
                case .providers: ProvidersSettingsView()
                case .prompts: PromptsSettingsView()
                case .history: HistoryView()
                case .permissions: PermissionsView()
                case .usage: UsageView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject var nav: SettingsNavigation
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Welcome to STTpro").font(.largeTitle.bold())
                Text("Hold **\(store.settings.holdToTalkHotkey.displayName)**, speak, and release — your words are typed into whatever app you're using.")
                    .font(.title3)
                HoldHotkeyConflictBanner()
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Allow the microphone and Accessibility", "Microphone to hear you; Accessibility so STTpro can press ⌘V for you.", .permissions)
                    step(2, "Add your API key", "Pick a speech-to-text provider (OpenAI, Groq, …) and paste your key. It's stored in your macOS Keychain.", .providers)
                    step(3, "Try it", "Open TextEdit, hold \(store.settings.holdToTalkHotkey.displayName), say something, and let go.", nil)
                }
                Text("STTpro lives in the menu bar (the microphone icon). There's no Dock icon.")
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String, _ tab: SettingsTab?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let tab {
                    Button("Open \(tab.title)") { nav.tab = tab }.padding(.top, 2)
                }
            }
        }
    }
}

/// Shown when the hold-to-talk key is also an enabled macOS shortcut — by
/// default ⌃Space is "Select the previous input source", which anyone with
/// two keyboard languages (e.g. English + Hebrew) has turned on.
struct HoldHotkeyConflictBanner: View {
    @EnvironmentObject var store: SettingsStore
    static let alternative = HotkeyBinding(keyCode: KeyCodes.space, modifiers: CarbonModifiers.option)

    var body: some View {
        let binding = store.settings.holdToTalkHotkey
        if let name = SystemShortcutConflicts.conflict(for: binding) {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(binding.displayName) is also your macOS shortcut “\(name)”", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text("macOS may switch keyboard language instead of starting dictation. Either use another hotkey for STTpro, or turn that shortcut off in System Settings › Keyboard › Keyboard Shortcuts › Input Sources (you can still switch languages with the 🌐 Globe key).")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if SystemShortcutConflicts.conflict(for: Self.alternative) == nil {
                        Button("Use \(Self.alternative.displayName) for STTpro") {
                            store.settings.holdToTalkHotkey = Self.alternative
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Open Keyboard Shortcuts…") { Permissions.openKeyboardShortcutsSettings() }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var store: SettingsStore
    @EnvironmentObject var nav: SettingsNavigation
    @ViewState private var launchError: String?

    var body: some View {
        Form {
            Section("Hotkeys") {
                LabeledContent("Hold to talk") { HotkeyRecorder(binding: $store.settings.holdToTalkHotkey, defaultValue: .defaultHoldToTalk) }
                HoldHotkeyConflictBanner()
                LabeledContent("Toggle recording") { HotkeyRecorder(binding: $store.settings.toggleRecordingHotkey, defaultValue: .defaultToggleRecording) }
                conflictWarning(store.settings.toggleRecordingHotkey)
                LabeledContent("Paste last transcript") { HotkeyRecorder(binding: $store.settings.pasteLastTranscriptHotkey, defaultValue: .defaultPasteLast) }
                conflictWarning(store.settings.pasteLastTranscriptHotkey)
                if !nav.failedHotkeys.isEmpty {
                    Label("Couldn't register \(nav.failedHotkeys.map(\.displayName).joined(separator: ", ")) — another app is using it. Pick a different shortcut.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("Transcription") {
                Picker("Language", selection: Binding(
                    get: { store.settings.languageHint ?? "" },
                    set: { store.settings.languageHint = $0.isEmpty ? nil : $0 })) {
                    ForEach(LanguageOption.all) { Text($0.name).tag($0.code) }
                }
                Toggle("Add a period at the end of sentences", isOn: $store.settings.addTrailingPeriod)
                Toggle("Skip very short recordings", isOn: $store.settings.skipShortRecordings)
                if store.settings.skipShortRecordings {
                    Stepper("Minimum length: \(store.settings.minRecordingDurationMs) ms",
                            value: $store.settings.minRecordingDurationMs, in: 100...2000, step: 50)
                }
                VStack(alignment: .leading) {
                    Slider(value: $store.settings.silenceThreshold, in: 0.2...0.95, step: 0.05) {
                        Text("Silence filter")
                    }
                    Text(String(format: "Drop results whose no-speech probability is above %.2f (Whisper models only).", store.settings.silenceThreshold))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Output") {
                Picker("After transcribing", selection: $store.settings.outputMode) {
                    ForEach(OutputMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Restore the previous clipboard after pasting", isOn: $store.settings.restoreClipboard)
            }

            Section("App") {
                Toggle("Show recording indicator", isOn: $store.settings.showRecordingIndicator)
                Toggle("Play sound cues", isOn: $store.settings.playSoundCues)
                Toggle("Launch at login", isOn: Binding(
                    get: { store.settings.launchAtLogin },
                    set: { setLaunchAtLogin($0) }))
                if let launchError { Text(launchError).font(.caption).foregroundStyle(.orange) }
                Stepper(store.settings.maxHistoryItems == 0 ? "Keep all history" : "Keep last \(store.settings.maxHistoryItems) transcripts",
                        value: $store.settings.maxHistoryItems, in: 0...10_000, step: 50)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func conflictWarning(_ binding: HotkeyBinding) -> some View {
        if let name = SystemShortcutConflicts.conflict(for: binding) {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(binding.displayName) is also the macOS shortcut “\(name)”, which may take it first.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Open Keyboard Shortcuts…") { Permissions.openKeyboardShortcutsSettings() }
                    .buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            store.settings.launchAtLogin = on
            launchError = nil
        } catch {
            launchError = "Couldn't change login item: \(error.localizedDescription). Move STTpro.app to /Applications and try again."
        }
    }
}

// MARK: - Hotkey recorder

struct HotkeyRecorder: View {
    @Binding var binding: HotkeyBinding
    var defaultValue: HotkeyBinding?
    @ViewState private var recording = false
    @ViewState private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? "Type shortcut… (Esc cancels)" : binding.displayName)
                    .frame(minWidth: 150)
            }
            .keyboardShortcut(.none)
            if let defaultValue, binding != defaultValue, !recording {
                Button { binding = defaultValue } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Reset to \(defaultValue.displayName)")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotkeyManager.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 0x35 { stop(); return nil } // Esc
            let mods = SystemShortcutConflicts.carbonModifiers(event.modifierFlags)
            let code = UInt32(event.keyCode)
            guard mods != 0 || KeyNames.isFunctionKey(code) else { NSSound.beep(); return nil }
            binding = HotkeyBinding(keyCode: code, modifiers: mods)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { HotkeyManager.shared.resume() }
        recording = false
    }
}

// MARK: - Permissions

struct PermissionsView: View {
    @ViewState private var mic = Permissions.microphone
    @ViewState private var ax = Permissions.accessibilityGranted
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                row(title: "Microphone", detail: "Needed to record your voice. The mic is only on while you hold the hotkey.",
                    granted: mic == .authorized) {
                    if mic == .notDetermined {
                        Button("Allow Microphone…") { Task { _ = await Permissions.requestMicrophone(); mic = Permissions.microphone } }
                    } else {
                        Button("Open Microphone Settings…") { Permissions.openMicrophoneSettings() }
                    }
                }
                row(title: "Accessibility", detail: "Needed to paste the text for you (STTpro presses ⌘V in the active app). Without it, text is left on the clipboard.",
                    granted: ax) {
                    Button("Allow Accessibility…") {
                        Permissions.promptAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                }
            } footer: {
                Text("In System Settings › Privacy & Security › Accessibility, turn on STTpro. If you rebuilt the app and it's already listed, remove it with − and add it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            mic = Permissions.microphone
            ax = Permissions.accessibilityGranted
        }
    }

    private func row<B: View>(title: String, detail: String, granted: Bool, @ViewBuilder button: () -> B) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2).foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !granted { button().padding(.top, 2) }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Usage

struct UsageView: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        let u = store.settings.usage
        Form {
            Section("Estimated usage") {
                LabeledContent("Transcriptions", value: "\(u.transcriptionCount)")
                LabeledContent("Audio", value: String(format: "%.1f min", u.totalAudioMinutes))
                LabeledContent("Speech-to-text cost", value: String(format: "$%.4f", u.totalWhisperCost))
                LabeledContent("Smart Prompt tokens", value: "\(u.postProcessTokensIn) in / \(u.postProcessTokensOut) out")
                LabeledContent("Smart Prompt cost", value: String(format: "$%.4f", u.totalPostProcessCost))
            }
            Section {
                Button("Reset usage") { store.settings.usage = UsageStats() }
            } footer: {
                Text("Estimates use OpenAI list prices (whisper-1 $0.006/min, gpt-4o-mini). Check your provider's dashboard for real billing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
