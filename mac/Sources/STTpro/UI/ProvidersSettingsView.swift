import SwiftUI
import STTproCore

struct ProvidersSettingsView: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Form {
            ProviderSection(title: "Speech to text", isStt: true, config: $store.settings.sttProvider, showsKey: true)
            ProviderSection(title: "Smart Prompts (LLM)", isStt: false, config: $store.settings.llmProvider,
                            showsKey: !store.settings.useSharedApiKey) {
                Toggle("Use the same API key as speech to text", isOn: $store.settings.useSharedApiKey)
            }
            Section {
                EmptyView()
            } footer: {
                Text("API keys are stored only in your macOS Keychain (item “\(KeychainStore.service)”). They are never written to settings files, logs, or history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderSection<Extra: View>: View {
    let title: String
    let isStt: Bool
    @Binding var config: ApiProviderConfig
    let showsKey: Bool
    @ViewBuilder var extra: () -> Extra

    init(title: String, isStt: Bool, config: Binding<ApiProviderConfig>, showsKey: Bool,
         @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        self.title = title
        self.isStt = isStt
        self._config = config
        self.showsKey = showsKey
        self.extra = extra
    }

    private var preset: ProviderPreset? { ApiProviders.preset(config.providerType, isStt: isStt) }

    var body: some View {
        Section(title) {
            Picker("Provider", selection: Binding(
                get: { config.providerType },
                set: { newType in
                    guard newType != config.providerType else { return }
                    config.providerType = newType
                    config.apiKeySlot = newType
                    config.baseUrl = nil
                    if let first = ApiProviders.preset(newType, isStt: isStt)?.suggestedModels.first { config.model = first }
                })) {
                ForEach(ApiProviders.presets(isStt: isStt)) { Text($0.displayName).tag($0.id) }
            }

            TextField("Base URL", text: Binding(
                get: { config.baseUrl ?? "" },
                set: { config.baseUrl = $0.isEmpty ? nil : $0 }),
                      prompt: Text(preset?.defaultBaseUrl.isEmpty == false ? preset!.defaultBaseUrl : "https://your-server/v1"))
                .textContentType(.URL)
                .autocorrectionDisabled()

            HStack {
                TextField("Model", text: $config.model)
                    .autocorrectionDisabled()
                if let models = preset?.suggestedModels, !models.isEmpty {
                    Menu {
                        ForEach(models, id: \.self) { m in Button(m) { config.model = m } }
                    } label: { Image(systemName: "chevron.down.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            extra()

            if showsKey && ApiProviders.requiresApiKey(config.providerType) {
                ApiKeyField(slot: config.apiKeySlot, providerName: preset?.displayName ?? config.providerType)
            }
        }
    }
}

/// Write-only key entry: the saved key is never displayed, only its last 4 chars.
private struct ApiKeyField: View {
    let slot: String
    let providerName: String
    @EnvironmentObject var store: SettingsStore
    @ViewState private var draft = ""
    @ViewState private var error: String?

    var body: some View {
        let hint: String? = { _ = store.keychainRevision; return KeychainStore.maskedHint(slot: slot) }()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("API key", text: $draft, prompt: Text(hint == nil ? "Paste your \(providerName) API key" : "Saved (\(hint!)) — paste to replace"))
                    .onSubmit(save)
                Button("Save", action: save).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if hint != nil {
                    Button("Remove", role: .destructive) {
                        KeychainStore.delete(slot: slot)
                        store.keychainRevision += 1
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let hint {
                Label("Key saved in Keychain (\(hint))", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Label("No key saved", systemImage: "key").font(.caption).foregroundStyle(.secondary)
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
