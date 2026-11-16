import Foundation

public enum AppPaths {
    /// ~/Library/Application Support/STTpro
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("STTpro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    public static var historyDatabase: URL { supportDirectory.appendingPathComponent("history.db") }
}

/// JSON settings file (no secrets — API keys are in the Keychain).
public enum SettingsFile {
    public static func load(from url: URL = AppPaths.settingsFile) -> AppSettings {
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            Log.error("Settings file unreadable; using defaults", error)
            return AppSettings()
        }
    }

    public static func save(_ settings: AppSettings, to url: URL = AppPaths.settingsFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
