import AppKit
import AVFoundation
import Combine
import ServiceManagement
import SwiftUI
import STTproCore

/// The "Settings" tab: a scroll of cards in the same order as the Windows app,
/// with a macOS-only Permissions card on top.
struct SettingsPage: View {
    @EnvironmentObject var nav: SettingsNavigation
    @ViewState private var showReset = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    PermissionsCard().id(SettingsSection.setup)
                    ProvidersCard().id(SettingsSection.providers)
                    UsageCard().id(SettingsSection.usage)
                    AudioCard().id(SettingsSection.audio)
                    TranscriptionCard().id(SettingsSection.transcription)
                    PromptsCard().id(SettingsSection.prompts)
                    HotkeysCard().id(SettingsSection.hotkeys)
                    OptionsCard().id(SettingsSection.options)
                    Button { showReset = true } label: {
                        Text("Reset All Settings to Default").frame(maxWidth: .infinity)
                    }
                    .sttButton(.secondary)
                    .padding(.bottom, 10)
                }
                .padding(.leading, 20)
                .padding(.trailing, 22)
                .padding(.top, 16)
            }
            .onAppear { scroll(proxy) }
            .onChange(of: nav.scrollTarget) { _, _ in scroll(proxy) }
        }
        .sheet(isPresented: $showReset) { ResetSettingsSheet(isPresented: $showReset) }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = nav.scrollTarget else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(target, anchor: .top) }
            nav.scrollTarget = nil
        }
    }
}

// MARK: - Permissions (macOS only)

struct PermissionsCard: View {
    @EnvironmentObject var store: SettingsStore
    @EnvironmentObject var nav: SettingsNavigation
    @ViewState private var mic = Permissions.microphone
    @ViewState private var ax = Permissions.accessibilityGranted
    @ViewState private var adHoc = Permissions.isAdHocSigned
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var keyMissing: Bool { _ = store.keychainRevision; return store.sttKeyMissing }
    private var allGood: Bool {
        mic == .authorized && ax && !keyMissing && SystemShortcutConflicts.conflict(for: store.settings.holdToTalkHotkey) == nil
    }

    var body: some View {
        Card(allGood ? "Permissions" : "Finish setup") {
            VStack(alignment: .leading, spacing: 12) {
                row("Microphone", ok: mic == .authorized,
                    detail: mic == .denied || mic == .restricted
                        ? "Turned off for STTpro. Enable it in System Settings, or reset and allow again."
                        : "Needed to hear you. The mic is only on while you dictate.") {
                    if mic == .notDetermined {
                        Button("Allow Microphone") { Task { _ = await Permissions.requestMicrophone(); refresh() } }.sttButton(.mini)
                    } else {
                        Button("Open Settings") { Permissions.openMicrophoneSettings() }.sttButton(.mini)
                        Button("Reset & ask again") { Permissions.resetAndRequest("Microphone"); refresh() }.sttButton(.mini)
                    }
                }
                row("Accessibility", ok: ax,
                    detail: "Lets STTpro press ⌘V in the app you're typing in. Without it the text stays on your clipboard.") {
                    Button("Allow Accessibility") {
                        Permissions.promptAccessibility()
                        Permissions.openAccessibilitySettings()
                    }.sttButton(.mini)
                    Button("Reset & ask again") { Permissions.resetAndRequest("Accessibility") }.sttButton(.mini)
                    Button("Relaunch STTpro") { Permissions.relaunch() }.sttButton(.mini)
                }
                if !ax {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Already switched on in System Settings but still red? That entry belongs to an older build. Click **Reset & ask again**, switch STTpro on in the list that opens, then **Relaunch STTpro**.")
                            .hintLabel().fixedSize(horizontal: false, vertical: true)
                        if adHoc {
                            Text("This build is ad-hoc signed, so macOS forgets the permission after every rebuild. Rebuild with `mac/scripts/build-app.sh` (without SIGN_IDENTITY=-) to sign it with the stable local identity.")
                                .hintLabel().fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, 30)
                }
                row("API key", ok: !keyMissing, detail: "Your speech-to-text provider key, stored in the macOS Keychain.") {
                    Button("Add key") { nav.scrollTarget = .providers }.sttButton(.mini)
                }
                if SystemShortcutConflicts.conflict(for: store.settings.holdToTalkHotkey) != nil {
                    row("Hotkey", ok: false,
                        detail: "\(store.settings.holdToTalkHotkey.displayName) is also the macOS keyboard-language shortcut, so dictation may not start.") {
                        Button("Use \(HoldHotkeyConflictBanner.alternative.displayName)") {
                            store.settings.holdToTalkHotkey = HoldHotkeyConflictBanner.alternative
                        }.sttButton(.mini)
                        Button("Details") { nav.scrollTarget = .hotkeys }.sttButton(.mini)
                    }
                }
            }
        }
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        mic = Permissions.microphone
        ax = Permissions.accessibilityGranted
    }

    private func row<B: View>(_ title: String, ok: Bool, detail: String, @ViewBuilder buttons: () -> B) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 18)).foregroundStyle(ok ? Theme.accentGreen : Theme.accentOrange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if !ok {
                    Text(detail).hintLabel().fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) { buttons() }.padding(.top, 2)
                }
            }
        }
    }
}

// MARK: - API providers

struct ProvidersCard: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Card("API Providers") {
            VStack(alignment: .leading, spacing: 8) {
                ProviderRow(label: "STT", isStt: true, config: $store.settings.sttProvider)
                ProviderRow(label: "LLM", isStt: false, config: $store.settings.llmProvider)

                if let hint = capabilityHint {
                    Text(hint).font(.system(size: 10.5)).foregroundStyle(Theme.accentGreen)
                }

                if ApiProviders.requiresApiKey(store.settings.sttProvider.providerType) {
                    ApiKeyEditor(label: "API Key", slot: store.settings.sttProvider.apiKeySlot,
                                 providerName: presetName(store.settings.sttProvider, isStt: true))
                        .padding(.top, 6)
                }

                Toggle("Use same API key for LLM", isOn: $store.settings.useSharedApiKey)
                    .toggleStyle(STTCheckboxStyle())
                    .padding(.top, 2)

                if !store.settings.useSharedApiKey && ApiProviders.requiresApiKey(store.settings.llmProvider.providerType) {
                    ApiKeyEditor(label: "LLM API Key", slot: store.settings.llmProvider.apiKeySlot,
                                 providerName: presetName(store.settings.llmProvider, isStt: false))
                        .padding(.top, 6)
                }

                BaseUrlEditor(label: "STT Base URL", isStt: true, config: $store.settings.sttProvider).padding(.top, 6)
                BaseUrlEditor(label: "LLM Base URL", isStt: false, config: $store.settings.llmProvider).padding(.top, 6)
            }
        }
    }

    private var capabilityHint: String? {
        let stt = store.settings.sttProvider.providerType
        guard let preset = ApiProviders.preset(stt, isStt: true), ApiProviders.preset(stt, isStt: false) != nil,
              stt != "custom" else { return nil }
        return "\(preset.displayName) supports both STT + LLM"
    }

    private func presetName(_ c: ApiProviderConfig, isStt: Bool) -> String {
        ApiProviders.preset(c.providerType, isStt: isStt)?.displayName ?? c.providerType
    }
}

private struct ProviderRow: View {
    let label: String
    let isStt: Bool
    @Binding var config: ApiProviderConfig

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .frame(width: 36, alignment: .leading)
            STTDropdown(options: ApiProviders.presets(isStt: isStt).map { ($0.id, $0.displayName) },
                        selection: Binding(get: { config.providerType }, set: select))
            ModelField(model: $config.model, suggestions: ApiProviders.preset(config.providerType, isStt: isStt)?.suggestedModels ?? [])
        }
    }

    private func select(_ id: String) {
        guard id != config.providerType else { return }
        config.providerType = id
        config.apiKeySlot = id
        config.baseUrl = nil
        if let first = ApiProviders.preset(id, isStt: isStt)?.suggestedModels.first { config.model = first }
    }
}

/// Editable ComboBox: type any model or pick a suggestion.
private struct ModelField: View {
    @Binding var model: String
    let suggestions: [String]
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $model, prompt: Text("model").foregroundStyle(Theme.textMuted))
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                .focused($focused).autocorrectionDisabled()
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { m in Button(m) { model = m } }
                } label: {
                    Image(systemName: "triangle.fill").rotationEffect(.degrees(180))
                        .font(.system(size: 7)).foregroundStyle(Theme.textMuted).frame(width: 16, height: 16)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bgInput))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.accentBlue : Theme.border, lineWidth: focused ? 1.5 : 1))
    }
}

/// Write-only key entry (PasswordBox + Save). The saved key is never shown.
struct ApiKeyEditor: View {
    let label: String
    let slot: String
    let providerName: String
    @EnvironmentObject var store: SettingsStore
    @ViewState private var draft = ""
    @ViewState private var error: String?

    var body: some View {
        let hint: String? = { _ = store.keychainRevision; return store.keyHint(slot: slot) }()
        VStack(alignment: .leading, spacing: 0) {
            Text(label).fieldLabel().padding(.bottom, 5)
            HStack(spacing: 8) {
                STTTextField(placeholder: hint == nil ? "Paste your \(providerName) API key" : "Saved (\(hint!)) — paste a new key to replace",
                             text: $draft, secure: true, onSubmit: save)
                Button("Save", action: save).sttButton(.primary)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Group {
                if let error {
                    Text(error).foregroundStyle(Theme.accentRed)
                } else if let hint {
                    Text("API key saved (\(slot), \(hint)).").foregroundStyle(Theme.textMuted)
                } else {
                    Text("No API key configured for \(providerName).").foregroundStyle(Theme.textMuted)
                }
            }
            .font(.system(size: 11))
            .padding(.top, 3)
            if hint != nil {
                Button("Remove key") {
                    KeychainStore.delete(slot: slot)
                    store.keychainRevision += 1
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accentRed).padding(.top, 2)
            }
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try KeychainStore.save(key, slot: slot)
            draft = ""
            error = nil
            store.keychainRevision += 1
        } catch {
            self.error = "Couldn't save to Keychain: \(error.localizedDescription)"
        }
    }
}

private struct BaseUrlEditor: View {
    let label: String
    let isStt: Bool
    @Binding var config: ApiProviderConfig

    var body: some View {
        let def = ApiProviders.preset(config.providerType, isStt: isStt)?.defaultBaseUrl ?? ""
        VStack(alignment: .leading, spacing: 0) {
            Text(label).fieldLabel().padding(.bottom, 5)
            STTTextField(placeholder: def.isEmpty ? "https://your-server/v1" : def,
                         text: Binding(get: { config.baseUrl ?? "" }, set: { config.baseUrl = $0.isEmpty ? nil : $0 }))
            Text(def.isEmpty ? "Required for custom providers (OpenAI-compatible, ending in /v1)." : "Leave empty to use the default: \(def)")
                .hintLabel().padding(.top, 3)
        }
    }
}

// MARK: - Usage

struct UsageCard: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        let u = store.settings.usage
        Card("API Usage") {
            Text("Estimated API costs based on usage. Actual billing may vary.").hintLabel().italic()
                .padding(.top, -4).padding(.bottom, 10)
            HStack(alignment: .top) {
                stat("Transcriptions", "\(u.transcriptionCount)", Theme.textPrimary)
                stat("Audio Minutes", String(format: "%.1f", u.totalAudioMinutes), Theme.textPrimary)
                stat("Est. Cost (approx)", String(format: "$%.2f", u.totalWhisperCost + u.totalPostProcessCost), Theme.accentGreen)
            }
            Text(String(format: "STT $%.4f · LLM %d in / %d out tokens, $%.4f",
                        u.totalWhisperCost, u.postProcessTokensIn, u.postProcessTokensOut, u.totalPostProcessCost))
                .hintLabel().padding(.top, 8)
            Button("Reset Usage") { store.settings.usage = UsageStats() }.sttButton(.mini).padding(.top, 10)
        }
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            Text(value).font(.system(size: 19, weight: .bold)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Audio

struct AudioCard: View {
    @EnvironmentObject var store: SettingsStore
    @ViewState private var devices = AudioDevices.inputs()

    var body: some View {
        Card("Audio") {
            Text("Microphone").fieldLabel().padding(.bottom, 5)
            STTDropdown(options: options, selection: Binding(
                get: { store.settings.microphoneUID ?? "" },
                set: { uid in
                    store.settings.microphoneUID = uid.isEmpty ? nil : uid
                    store.settings.microphoneName = devices.first { $0.uid == uid }?.name
                }))
        }
        .onAppear { devices = AudioDevices.inputs() }
    }

    private var options: [(value: String, label: String)] {
        var opts: [(value: String, label: String)] = [("", "System default")]
        opts += devices.map { ($0.uid, $0.name) }
        if let uid = store.settings.microphoneUID, !devices.contains(where: { $0.uid == uid }) {
            opts.append((uid, "\(store.settings.microphoneName ?? "Saved microphone") — not connected"))
        }
        return opts
    }
}

// MARK: - Transcription

struct TranscriptionCard: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Card("Transcription") {
            Text("Language").fieldLabel().padding(.bottom, 5)
            STTDropdown(options: LanguageOption.all.map { ($0.code, $0.name) }, selection: Binding(
                get: { store.settings.languageHint ?? "" },
                set: { store.settings.languageHint = $0.isEmpty ? nil : $0 }))
                .padding(.bottom, 10)
            Text("Output Mode").fieldLabel().padding(.bottom, 5)
            STTDropdown(options: [
                (OutputMode.clipboardPaste, "Clipboard Paste (⌘V)"),
                (OutputMode.copyOnly, "Copy to Clipboard Only"),
                (OutputMode.saveOnly, "Save to History Only"),
            ], selection: $store.settings.outputMode)
        }
    }
}

// MARK: - Smart Prompts

struct PromptsCard: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Card("Smart Prompts") {
            VStack(alignment: .leading, spacing: 2) {
                Text("Press the hotkey (default ⌃⇧1, 2, 3…) to record with a prompt. Your recording is post-processed through the selected prompt.")
                    .hintLabel().fixedSize(horizontal: false, vertical: true)
                Text("Click a name or text below to edit a prompt.").hintLabel().italic()
            }
            .padding(.top, -4).padding(.bottom, 10)

            HStack(spacing: 18) {
                Text("Mode:").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                STTRadio(label: "Toggle (press to start / stop)", selected: store.settings.promptHotkeyMode == .toggle) {
                    store.settings.promptHotkeyMode = .toggle
                }
                STTRadio(label: "Hold (record while held)", selected: store.settings.promptHotkeyMode == .hold) {
                    store.settings.promptHotkeyMode = .hold
                }
            }
            .padding(.bottom, 12)

            ForEach($store.settings.prompts) { $prompt in
                PromptEditor(prompt: $prompt, defaultHotkey: defaultHotkey(for: prompt.id)) {
                    store.settings.prompts.removeAll { $0.id == prompt.id }
                }
            }

            Button("+ Add Prompt") {
                store.settings.prompts.append(PromptTemplate(name: "New Prompt",
                    prompt: "Rewrite this transcription. Output only the result, nothing else."))
            }
            .sttButton(.mini).padding(.top, 4)
        }
    }

    private func defaultHotkey(for id: UUID) -> HotkeyBinding? {
        guard let idx = store.settings.prompts.filter(\.enabled).firstIndex(where: { $0.id == id }) else { return nil }
        return HotkeyBinding.defaultPrompt(index: idx)
    }
}

private struct PromptEditor: View {
    @Binding var prompt: PromptTemplate
    let defaultHotkey: HotkeyBinding?
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if prompt.enabled, let current = prompt.hotkey ?? defaultHotkey {
                    HotkeyRecorder(binding: Binding(get: { current }, set: { prompt.hotkey = ($0 == defaultHotkey ? nil : $0) }),
                                   defaultValue: defaultHotkey, compact: true)
                }
                TextField("", text: $prompt.name)
                    .textFieldStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .padding(.bottom, 1)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                Spacer(minLength: 8)
                Toggle("Enabled", isOn: $prompt.enabled).toggleStyle(STTCheckboxStyle())
                    .font(.system(size: 11))
                Button(action: onDelete) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMuted)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Delete prompt")
            }
            TextEditor(text: $prompt.prompt)
                .font(.system(size: 11)).foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4).padding(.vertical, 3)
                .frame(minHeight: 54)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bgCard))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bgInput))
        .opacity(prompt.enabled ? 1 : 0.6)
        .padding(.bottom, 10)
    }
}

// MARK: - Hotkeys

struct HotkeysCard: View {
    @EnvironmentObject var store: SettingsStore
    @EnvironmentObject var nav: SettingsNavigation

    var body: some View {
        Card("Hotkeys") {
            Text("Click a hotkey, then hold your modifiers (⌃ Control / ⌥ Option / ⇧ Shift / ⌘ Command) and press the final key — e.g. ⌃⇧M. It saves automatically. Press Escape to cancel.")
                .hintLabel().fixedSize(horizontal: false, vertical: true)
                .padding(.top, -4).padding(.bottom, 12)
            row("Hold to talk", $store.settings.holdToTalkHotkey, .defaultHoldToTalk)
            row("Toggle recording", $store.settings.toggleRecordingHotkey, .defaultToggleRecording)
            row("Paste last", $store.settings.pasteLastTranscriptHotkey, .defaultPasteLast)
            HoldHotkeyConflictBanner().padding(.top, 4)
            if !nav.failedHotkeys.isEmpty {
                Label("Couldn't register \(nav.failedHotkeys.map(\.displayName).joined(separator: ", ")) — another app is using it. Pick a different shortcut.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.accentOrange).padding(.top, 6)
            }
        }
    }

    private func row(_ title: String, _ binding: Binding<HotkeyBinding>, _ def: HotkeyBinding) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).frame(width: 140, alignment: .leading)
            HotkeyRecorder(binding: binding, defaultValue: nil)
            Button("Reset") { binding.wrappedValue = def }.sttButton(.mini).help("Reset to \(def.displayName)")
        }
        .padding(.bottom, 8)
    }
}

/// Click, then press a key combination. Saves immediately; Esc cancels.
struct HotkeyRecorder: View {
    @Binding var binding: HotkeyBinding
    var defaultValue: HotkeyBinding?
    var compact = false
    @ViewState private var recording = false
    @ViewState private var monitor: Any?

    var body: some View {
        Button(action: { recording ? stop() : start() }) {
            Text(recording ? "Press keys..." : binding.displayName)
                .font(compact ? .system(size: 10, design: .monospaced) : .system(size: 12))
                .foregroundStyle(recording ? Theme.accentBlue : Theme.textPrimary)
                .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
        }
        .buttonStyle(STTButtonStyle(kind: .hotkey))
        .overlay(recording ? RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.accentBlue, lineWidth: 1.5) : nil)
        .scaleEffect(compact ? 0.85 : 1, anchor: .leading)
        .help("Click to rebind hotkey")
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
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accentOrange)
                Text("macOS may switch keyboard language instead of starting dictation. Use another hotkey for STTpro, or turn that shortcut off in System Settings › Keyboard › Keyboard Shortcuts › Input Sources (you can still switch languages with the 🌐 Globe key).")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if SystemShortcutConflicts.conflict(for: Self.alternative) == nil {
                        Button("Use \(Self.alternative.displayName) for STTpro") { store.settings.holdToTalkHotkey = Self.alternative }
                            .sttButton(.primary)
                    }
                    Button("Open Keyboard Shortcuts…") { Permissions.openKeyboardShortcutsSettings() }.sttButton(.secondary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.badgeOrangeBg))
        }
    }
}

// MARK: - Options

struct OptionsCard: View {
    @EnvironmentObject var store: SettingsStore
    @ViewState private var launchError: String?

    var body: some View {
        Card("Options") {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Show recording indicator", isOn: $store.settings.showRecordingIndicator)
                Toggle("Restore clipboard after paste", isOn: $store.settings.restoreClipboard)
                Toggle("Add period at end of sentences", isOn: $store.settings.addTrailingPeriod)
                Toggle("Skip very short recordings (under 0.25 s)", isOn: Binding(
                    get: { store.settings.skipShortRecordings },
                    set: { store.settings.skipShortRecordings = $0 }))
                Toggle("Play sound cues", isOn: $store.settings.playSoundCues)
                Toggle("Launch at login", isOn: Binding(get: { store.settings.launchAtLogin }, set: setLaunchAtLogin))
            }
            .toggleStyle(STTCheckboxStyle())
            if let launchError { Text(launchError).font(.system(size: 11)).foregroundStyle(Theme.accentOrange) }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Silence sensitivity:").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Text(String(format: "%.2f", store.settings.silenceThreshold))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accentBlue)
                }
                Slider(value: $store.settings.silenceThreshold, in: 0.3...0.95, step: 0.05).padding(.top, 6)
                Text("Lower = keep more audio (less filtering). Higher = filter out more silence/noise.")
                    .hintLabel().padding(.top, 2)
            }
            .padding(.top, 12)

            labeled("History retention:") {
                STTDropdown(options: [(0, "Save everything"), (20, "Keep last 20"), (50, "Keep last 50"),
                                      (100, "Keep last 100"), (500, "Keep last 500")],
                            selection: $store.settings.maxHistoryItems, width: 190)
            }
            labeled("Appearance:") {
                STTDropdown(options: [("system", "Follow macOS"), ("light", "Light"), ("dark", "Dark")],
                            selection: Binding(get: { store.settings.themeMode }, set: {
                                store.settings.themeMode = $0
                                Theme.apply(mode: $0)
                            }), width: 190)
            }
        }
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            content()
        }
        .padding(.top, 12)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            store.settings.launchAtLogin = on
            launchError = nil
        } catch {
            launchError = "Couldn't change login item: \(error.localizedDescription). Install STTpro in /Applications first."
        }
    }
}

// MARK: - Reset dialog (ResetSettingsDialog.xaml)

struct ResetSettingsSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var store: SettingsStore
    @ViewState private var resetPrompts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reset Settings").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 12)
            Text("This will restore all settings to their defaults. Your API keys and transcription history will not be affected.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)
            Toggle("Also reset prompts to defaults", isOn: $resetPrompts).toggleStyle(STTCheckboxStyle())
                .padding(.bottom, 22)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { isPresented = false }.sttButton(.secondary).keyboardShortcut(.cancelAction)
                Button("Reset") { reset() }.sttButton(.delete)
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 22)
        .frame(width: 400)
        .background(Theme.bgCard)
    }

    private func reset() {
        let old = store.settings
        var fresh = AppSettings()
        fresh.usage = old.usage
        fresh.hasCompletedOnboarding = true
        if !resetPrompts { fresh.prompts = old.prompts }
        store.settings = fresh
        Theme.apply(mode: fresh.themeMode)
        isPresented = false
    }
}
