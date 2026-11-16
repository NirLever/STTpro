import Foundation
import Combine
import STTproCore

/// Observable wrapper around settings.json; every change is saved.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            do { try SettingsFile.save(settings) } catch { Log.error("Saving settings failed", error) }
        }
    }

    /// Bumped when a Keychain key is saved/removed so views refresh.
    @Published var keychainRevision = 0

    init() {
        settings = SettingsFile.load()
    }

    func apiKey(slot: String) -> String? { KeychainStore.load(slot: slot) }

    var sttKeyMissing: Bool {
        ApiProviders.requiresApiKey(settings.sttProvider.providerType)
            && !KeychainStore.hasKey(slot: settings.sttProvider.apiKeySlot)
    }
}
