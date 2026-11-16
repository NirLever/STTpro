import SwiftUI
import STTproCore

struct PromptsSettingsView: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Prompt hotkeys", selection: $store.settings.promptHotkeyMode) {
                    Text("Press to start, press again to stop").tag(PromptHotkeyMode.toggle)
                    Text("Hold while speaking").tag(PromptHotkeyMode.hold)
                }
            } footer: {
                Text("A Smart Prompt records like dictation, then sends the text through your LLM with the prompt below before pasting. Default hotkeys are ⌃⇧1…⌃⇧9 in list order (enabled prompts only).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach($store.settings.prompts) { $prompt in
                Section {
                    HStack {
                        TextField("Name", text: $prompt.name).font(.headline)
                        Toggle("Enabled", isOn: $prompt.enabled).labelsHidden()
                    }
                    TextEditor(text: $prompt.prompt)
                        .font(.body)
                        .frame(minHeight: 70)
                    HStack {
                        Text("Hotkey").foregroundStyle(.secondary)
                        if prompt.enabled, let def = defaultHotkey(for: prompt.id) {
                            HotkeyRecorder(binding: Binding(
                                get: { prompt.hotkey ?? def },
                                set: { prompt.hotkey = ($0 == def ? nil : $0) }), defaultValue: def)
                        } else if prompt.enabled, let custom = prompt.hotkey {
                            HotkeyRecorder(binding: Binding(get: { custom }, set: { prompt.hotkey = $0 }), defaultValue: nil)
                        } else {
                            Text(prompt.enabled ? "Only the first 9 get a default hotkey" : "Disabled").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            store.settings.prompts.removeAll { $0.id == prompt.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section {
                Button {
                    store.settings.prompts.append(PromptTemplate(name: "New prompt", prompt: "Rewrite this transcription … Output only the result."))
                } label: { Label("Add Smart Prompt", systemImage: "plus") }
                Button("Restore default prompts") { store.settings.prompts = AppSettings().prompts }
            }
        }
        .formStyle(.grouped)
    }

    private func defaultHotkey(for id: UUID) -> HotkeyBinding? {
        guard let idx = store.settings.prompts.filter(\.enabled).firstIndex(where: { $0.id == id }) else { return nil }
        return HotkeyBinding.defaultPrompt(index: idx)
    }
}
