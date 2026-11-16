import Foundation

// Mirrors src/STTpro.Core/Settings/AppSettings.cs. Hotkeys use macOS virtual
// key codes and Carbon modifier masks instead of Win32 values.

public enum CarbonModifiers {
    public static let command: UInt32 = 0x0100   // cmdKey
    public static let shift: UInt32 = 0x0200     // shiftKey
    public static let option: UInt32 = 0x0800    // optionKey
    public static let control: UInt32 = 0x1000   // controlKey
}

public enum KeyCodes {
    public static let space: UInt32 = 0x31
    public static let v: UInt32 = 0x09
    /// kVK_ANSI_1 … kVK_ANSI_9
    public static let digits: [UInt32] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
}

public struct HotkeyBinding: Codable, Equatable, Hashable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var displayName: String

    public init(keyCode: UInt32, modifiers: UInt32, displayName: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayName = displayName ?? KeyNames.display(keyCode: keyCode, modifiers: modifiers)
    }

    public static let defaultHoldToTalk = HotkeyBinding(keyCode: KeyCodes.space, modifiers: CarbonModifiers.control)
    public static let defaultToggleRecording = HotkeyBinding(keyCode: KeyCodes.space, modifiers: CarbonModifiers.control | CarbonModifiers.shift)
    public static let defaultPasteLast = HotkeyBinding(keyCode: KeyCodes.v, modifiers: CarbonModifiers.control | CarbonModifiers.shift)

    /// Default Smart Prompt hotkey: ⌃⇧1 … ⌃⇧9 (same as Ctrl+Shift+N on Windows).
    public static func defaultPrompt(index: Int) -> HotkeyBinding? {
        guard index >= 0, index < KeyCodes.digits.count else { return nil }
        return HotkeyBinding(keyCode: KeyCodes.digits[index], modifiers: CarbonModifiers.control | CarbonModifiers.shift)
    }
}

public struct PromptTemplate: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var prompt: String
    public var enabled: Bool
    /// nil = default ⌃⇧{position among enabled prompts + 1}
    public var hotkey: HotkeyBinding?

    public init(id: UUID = UUID(), name: String, prompt: String, enabled: Bool = true, hotkey: HotkeyBinding? = nil) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.enabled = enabled
        self.hotkey = hotkey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        hotkey = try c.decodeIfPresent(HotkeyBinding.self, forKey: .hotkey)
    }
}

public struct UsageStats: Codable, Equatable {
    public var transcriptionCount = 0
    public var totalAudioMinutes = 0.0
    public var totalWhisperCost = 0.0
    public var postProcessTokensIn = 0
    public var postProcessTokensOut = 0
    public var totalPostProcessCost = 0.0
    public init() {}
}

/// Configuration for an OpenAI-compatible provider (STT or LLM).
public struct ApiProviderConfig: Codable, Equatable {
    /// Preset id: "openai", "groq", "gemini", "deepseek", "openrouter", "local", "custom".
    public var providerType: String
    /// Override base URL; nil/empty = preset default.
    public var baseUrl: String?
    /// Keychain slot that holds this provider's API key.
    public var apiKeySlot: String
    public var model: String

    public init(providerType: String, baseUrl: String? = nil, apiKeySlot: String, model: String) {
        self.providerType = providerType
        self.baseUrl = baseUrl
        self.apiKeySlot = apiKeySlot
        self.model = model
    }
}

public enum OutputMode: String, Codable, CaseIterable, Identifiable {
    case clipboardPaste = "ClipboardPaste"
    case copyOnly = "CopyOnly"
    case saveOnly = "SaveOnly"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .clipboardPaste: return "Paste into the active app"
        case .copyOnly: return "Copy to clipboard only"
        case .saveOnly: return "Save to history only"
        }
    }
}

public enum PromptHotkeyMode: String, Codable, CaseIterable, Identifiable {
    case toggle, hold
    public var id: String { rawValue }
}

public struct AppSettings: Codable, Equatable {
    public var languageHint: String? = nil
    /// CoreAudio device UID; nil = system default input.
    public var microphoneUID: String? = nil
    /// Remembered so a mic that's unplugged can still be shown by name.
    public var microphoneName: String? = nil
    /// "system" (follow macOS), "light" or "dark".
    public var themeMode = "system"
    public var outputMode: OutputMode = .clipboardPaste

    public var sttProvider = ApiProviderConfig(providerType: "openai", apiKeySlot: "openai", model: "whisper-1")
    public var llmProvider = ApiProviderConfig(providerType: "openai", apiKeySlot: "openai", model: "gpt-4o-mini")
    /// LLM uses the STT provider's key slot.
    public var useSharedApiKey = true

    public var holdToTalkHotkey = HotkeyBinding.defaultHoldToTalk
    public var toggleRecordingHotkey = HotkeyBinding.defaultToggleRecording
    public var pasteLastTranscriptHotkey = HotkeyBinding.defaultPasteLast

    public var launchAtLogin = false
    public var showRecordingIndicator = true
    public var playSoundCues = true
    /// 0 = unlimited.
    public var maxHistoryItems = 0
    public var restoreClipboard = true
    /// Segments with no_speech_prob above this are treated as silence.
    public var silenceThreshold = 0.6
    public var addTrailingPeriod = true
    public var skipShortRecordings = true
    public var minRecordingDurationMs = 250

    public var promptHotkeyMode: PromptHotkeyMode = .toggle
    public var prompts: [PromptTemplate] = [
        PromptTemplate(name: "Organize", prompt: "Clean up and organize this transcription. Fix grammar and structure it clearly. Do not add information that wasn't in the original. Output only the organized text, nothing else."),
        PromptTemplate(name: "Summarize", prompt: "Summarize this transcription concisely. Keep the key points. Output only the summary, nothing else."),
        PromptTemplate(name: "Action Items", prompt: "Extract actionable items from this transcription as a bullet-point list. Do not add items that weren't mentioned. Output only the list, nothing else."),
    ]

    public var usage = UsageStats()
    /// Set after the first-run flow has been shown once.
    public var hasCompletedOnboarding = false

    public init() {}

    /// The key slot the LLM should read from.
    public var effectiveLlmKeySlot: String {
        useSharedApiKey ? sttProvider.apiKeySlot : llmProvider.apiKeySlot
    }

    /// Enabled prompts paired with the hotkey that triggers each.
    public var enabledPromptBindings: [(prompt: PromptTemplate, hotkey: HotkeyBinding?)] {
        prompts.filter(\.enabled).enumerated().map { i, p in (p, p.hotkey ?? HotkeyBinding.defaultPrompt(index: i)) }
    }

    // Tolerant decoding: any missing key keeps its default, so adding fields
    // never wipes a user's settings file.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ current: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? current
        }
        languageHint = (try? c.decodeIfPresent(String.self, forKey: .languageHint)) ?? nil
        microphoneUID = (try? c.decodeIfPresent(String.self, forKey: .microphoneUID)) ?? nil
        microphoneName = (try? c.decodeIfPresent(String.self, forKey: .microphoneName)) ?? nil
        themeMode = get(.themeMode, themeMode)
        outputMode = get(.outputMode, outputMode)
        sttProvider = get(.sttProvider, sttProvider)
        llmProvider = get(.llmProvider, llmProvider)
        useSharedApiKey = get(.useSharedApiKey, useSharedApiKey)
        holdToTalkHotkey = get(.holdToTalkHotkey, holdToTalkHotkey)
        toggleRecordingHotkey = get(.toggleRecordingHotkey, toggleRecordingHotkey)
        pasteLastTranscriptHotkey = get(.pasteLastTranscriptHotkey, pasteLastTranscriptHotkey)
        launchAtLogin = get(.launchAtLogin, launchAtLogin)
        showRecordingIndicator = get(.showRecordingIndicator, showRecordingIndicator)
        playSoundCues = get(.playSoundCues, playSoundCues)
        maxHistoryItems = get(.maxHistoryItems, maxHistoryItems)
        restoreClipboard = get(.restoreClipboard, restoreClipboard)
        silenceThreshold = get(.silenceThreshold, silenceThreshold)
        addTrailingPeriod = get(.addTrailingPeriod, addTrailingPeriod)
        skipShortRecordings = get(.skipShortRecordings, skipShortRecordings)
        minRecordingDurationMs = get(.minRecordingDurationMs, minRecordingDurationMs)
        promptHotkeyMode = get(.promptHotkeyMode, promptHotkeyMode)
        prompts = get(.prompts, prompts)
        usage = get(.usage, usage)
        hasCompletedOnboarding = get(.hasCompletedOnboarding, hasCompletedOnboarding)
    }
}

public struct ProviderPreset: Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let defaultBaseUrl: String
    public let suggestedModels: [String]
}

/// Same presets as the Windows app.
public enum ApiProviders {
    public static let sttPresets: [ProviderPreset] = [
        .init(id: "openai", displayName: "OpenAI", defaultBaseUrl: "https://api.openai.com/v1",
              suggestedModels: ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"]),
        .init(id: "groq", displayName: "Groq", defaultBaseUrl: "https://api.groq.com/openai/v1",
              suggestedModels: ["whisper-large-v3", "whisper-large-v3-turbo", "distil-whisper-large-v3-en"]),
        .init(id: "gemini", displayName: "Google Gemini", defaultBaseUrl: "https://generativelanguage.googleapis.com/v1beta/openai",
              suggestedModels: ["gemini-2.0-flash"]),
        .init(id: "custom", displayName: "Custom (OpenAI-compatible)", defaultBaseUrl: "", suggestedModels: []),
    ]

    public static let llmPresets: [ProviderPreset] = [
        .init(id: "openai", displayName: "OpenAI", defaultBaseUrl: "https://api.openai.com/v1",
              suggestedModels: ["gpt-4o-mini", "gpt-4.1-nano", "gpt-4.1-mini", "gpt-4o", "gpt-4.1", "o4-mini", "o3-mini"]),
        .init(id: "groq", displayName: "Groq", defaultBaseUrl: "https://api.groq.com/openai/v1",
              suggestedModels: ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "gemma2-9b-it"]),
        .init(id: "gemini", displayName: "Google Gemini", defaultBaseUrl: "https://generativelanguage.googleapis.com/v1beta/openai",
              suggestedModels: ["gemini-2.0-flash", "gemini-2.5-flash", "gemini-2.5-pro"]),
        .init(id: "deepseek", displayName: "DeepSeek", defaultBaseUrl: "https://api.deepseek.com/v1",
              suggestedModels: ["deepseek-chat", "deepseek-reasoner"]),
        .init(id: "openrouter", displayName: "OpenRouter", defaultBaseUrl: "https://openrouter.ai/api/v1",
              suggestedModels: ["openai/gpt-4o-mini", "anthropic/claude-3.5-sonnet", "meta-llama/llama-3.3-70b-instruct"]),
        .init(id: "local", displayName: "Local (Ollama)", defaultBaseUrl: "http://localhost:11434/v1",
              suggestedModels: ["llama3.2", "mistral", "phi3"]),
        .init(id: "custom", displayName: "Custom (OpenAI-compatible)", defaultBaseUrl: "", suggestedModels: []),
    ]

    public static func presets(isStt: Bool) -> [ProviderPreset] { isStt ? sttPresets : llmPresets }

    public static func preset(_ id: String, isStt: Bool) -> ProviderPreset? {
        presets(isStt: isStt).first { $0.id == id }
    }

    public static func effectiveBaseUrl(_ config: ApiProviderConfig, isStt: Bool) -> String {
        if let url = config.baseUrl?.trimmingCharacters(in: .whitespaces), !url.isEmpty { return url }
        let def = preset(config.providerType, isStt: isStt)?.defaultBaseUrl ?? ""
        return def.isEmpty ? "https://api.openai.com/v1" : def
    }

    /// Local servers (Ollama) usually don't need a key.
    public static func requiresApiKey(_ providerType: String) -> Bool { providerType != "local" }
}

public struct LanguageOption: Identifiable, Hashable {
    public let code: String   // "" = auto-detect
    public let name: String
    public var id: String { code }

    public static let all: [LanguageOption] = [
        .init(code: "", name: "Auto-detect"),
        .init(code: "en", name: "English"),
        .init(code: "he", name: "Hebrew (עברית)"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "fr", name: "French"),
        .init(code: "es", name: "Spanish"),
        .init(code: "de", name: "German"),
        .init(code: "ru", name: "Russian"),
        .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "nl", name: "Dutch"),
        .init(code: "zh", name: "Chinese"),
        .init(code: "ja", name: "Japanese"),
    ]
}
