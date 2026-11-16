import Foundation
import Combine
import STTproCore

/// Observable wrapper around settings.json; every change is saved.
@MainActor
final class SettingsStore: ObservableObject {
    private let persists: Bool

    @Published var settings: AppSettings {
        didSet {
            guard persists, settings != oldValue else { return }
            do { try SettingsFile.save(settings) } catch { Log.error("Saving settings failed", error) }
        }
    }

    /// Bumped when a Keychain key is saved/removed so views refresh.
    @Published var keychainRevision = 0

    init(inMemory: Bool = false) {
        persists = !inMemory
        settings = inMemory ? AppSettings() : SettingsFile.load()
    }

    /// "…abcd" for a saved key, nil when none. (In-memory stores never touch the Keychain.)
    func keyHint(slot: String) -> String? {
        persists ? KeychainStore.maskedHint(slot: slot) : nil
    }

    var sttKeyMissing: Bool {
        ApiProviders.requiresApiKey(settings.sttProvider.providerType)
            && keyHint(slot: settings.sttProvider.apiKeySlot) == nil
    }
}
