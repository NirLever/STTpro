namespace STTpro.Core.Settings;

public class HotkeyBinding
{
    public uint Modifiers { get; set; }
    public uint KeyCode { get; set; }
    public string DisplayName { get; set; } = "";
}

public class PromptTemplate
{
    public string Name { get; set; } = "";
    public string Prompt { get; set; } = "";
    public bool Enabled { get; set; } = true;
    /// <summary>
    /// Custom hotkey binding. Null = use default Ctrl+Shift+{index+1}.
    /// </summary>
    public HotkeyBinding? Hotkey { get; set; }
}

public class UsageStats
{
    public int TranscriptionCount { get; set; }
    public double TotalAudioMinutes { get; set; }
    public double TotalWhisperCost { get; set; }
    public int PostProcessTokensIn { get; set; }
    public int PostProcessTokensOut { get; set; }
    public double TotalPostProcessCost { get; set; }
}

/// <summary>
/// Configuration for an API provider (used for both STT and LLM).
/// Most providers expose OpenAI-compatible endpoints, so we just need
/// a base URL, model name, and credential slot.
/// </summary>
public class ApiProviderConfig
{
    /// <summary>
    /// Provider preset identifier: "openai", "groq", "deepseek", "anthropic", "local", "custom".
    /// Controls default base URL and display name.
    /// </summary>
    public string ProviderType { get; set; } = "openai";

    /// <summary>
    /// Override base URL. Null = use default for the provider type.
    /// E.g. "https://api.groq.com/openai" for Groq, "http://localhost:11434/v1" for Ollama.
    /// </summary>
    public string? BaseUrl { get; set; }

    /// <summary>
    /// Credential store slot name. Each provider gets its own API key slot.
    /// Defaults to the provider type (e.g., "openai", "groq").
    /// </summary>
    public string ApiKeySlot { get; set; } = "default";

    /// <summary>
    /// Model name to use (e.g., "whisper-1", "gpt-4o-mini", "llama-3.3-70b-versatile").
    /// </summary>
    public string Model { get; set; } = "";
}

public class AppSettings
{
    public string SelectedMicrophoneId { get; set; } = "";
    public int SelectedMicrophoneIndex { get; set; } = -1;
    public string OutputMode { get; set; } = "ClipboardPaste";
    public string? LanguageHint { get; set; }

    // --- Provider configuration ---

    /// <summary>
    /// STT (Speech-to-Text) provider configuration.
    /// Default: OpenAI Whisper.
    /// </summary>
    public ApiProviderConfig SttProvider { get; set; } = new()
    {
        ProviderType = "openai",
        ApiKeySlot = "default",
        Model = "whisper-1"
    };

    /// <summary>
    /// LLM (post-processing / summarization) provider configuration.
    /// Default: OpenAI GPT. Can be a different provider than STT.
    /// </summary>
    public ApiProviderConfig LlmProvider { get; set; } = new()
    {
        ProviderType = "openai",
        ApiKeySlot = "default",
        Model = "gpt-4o-mini"
    };

    /// <summary>
    /// When true, the LLM provider uses the same API key as the STT provider
    /// (both read from SttProvider.ApiKeySlot).
    /// </summary>
    public bool UseSharedApiKey { get; set; } = true;

    // --- Legacy fields (kept for migration, mapped to SttProvider/LlmProvider on load) ---
    public string? SttProviderName { get; set; }
    public string? WhisperModel { get; set; }
    public string? PostProcessModel { get; set; }

    public HotkeyBinding HoldToTalkHotkey { get; set; } = new()
    {
        Modifiers = 0x0002, // Ctrl
        KeyCode = 0x20,     // Space
        DisplayName = "Ctrl + Space"
    };

    public HotkeyBinding ToggleRecordingHotkey { get; set; } = new()
    {
        Modifiers = 0x0002 | 0x0004, // Ctrl + Shift
        KeyCode = 0x20,               // Space
        DisplayName = "Ctrl + Shift + Space"
    };

    public HotkeyBinding PasteLastTranscriptHotkey { get; set; } = new()
    {
        Modifiers = 0x0002 | 0x0004, // Ctrl + Shift
        KeyCode = 0x56,               // V
        DisplayName = "Ctrl + Shift + V"
    };

    public bool LaunchOnStartup { get; set; }

    /// <summary>
    /// UI appearance: "system" (follow Windows), "light", or "dark".
    /// </summary>
    public string ThemeMode { get; set; } = "system";

    public bool ShowRecordingIndicator { get; set; } = true;
    public bool PlaySoundCues { get; set; } = true;
    public int PreRollMs { get; set; } = 300;
    /// <summary>
    /// 0 = save everything (unlimited), N = keep only last N transcripts.
    /// </summary>
    public int MaxHistoryItems { get; set; } = 0;
    public bool RestoreClipboard { get; set; } = true;

    /// <summary>
    /// Silence detection threshold (0.0 - 1.0). Higher = more aggressive filtering.
    /// Chunks with no_speech_prob above this are treated as silence.
    /// Default: 0.6 for chunks, 0.7 for final segment.
    /// </summary>
    public double SilenceThreshold { get; set; } = 0.6;

    /// <summary>
    /// Whether to add a trailing period at the end of transcribed sentences
    /// that don't already end with punctuation.
    /// </summary>
    public bool AddTrailingPeriod { get; set; } = true;

    /// <summary>
    /// When true, recordings shorter than MinRecordingDurationMs are
    /// silently discarded instead of being sent to the STT provider.
    /// </summary>
    public bool SkipShortRecordings { get; set; } = true;

    /// <summary>
    /// Minimum recording duration in milliseconds. Recordings shorter than
    /// this are skipped when SkipShortRecordings is enabled. Default: 250 ms.
    /// </summary>
    public int MinRecordingDurationMs { get; set; } = 250;

    // Smart Prompts
    /// <summary>
    /// "toggle" = press hotkey to start, press again to stop.
    /// "hold" = hold the hotkey to record, release to stop and transcribe.
    /// </summary>
    public string PromptHotkeyMode { get; set; } = "toggle";
    public List<PromptTemplate> Prompts { get; set; } = new()
    {
        new() { Name = "Organize", Prompt = "Clean up and organize this transcription. Fix grammar and structure it clearly. Do not add information that wasn't in the original. Output only the organized text, nothing else." },
        new() { Name = "Summarize", Prompt = "Summarize this transcription concisely. Keep the key points. Output only the summary, nothing else." },
        new() { Name = "Action Items", Prompt = "Extract actionable items from this transcription as a bullet-point list. Do not add items that weren't mentioned. Output only the list, nothing else." },
    };

    // Usage tracking
    public UsageStats Usage { get; set; } = new();

    /// <summary>Returns a fresh AppSettings instance with all defaults.</summary>
    public static AppSettings CreateDefaults() => new();

    public static readonly HotkeyBinding DefaultHoldToTalk = new() { Modifiers = 0x0002, KeyCode = 0x20, DisplayName = "Ctrl + Space" };
    public static readonly HotkeyBinding DefaultToggleRecording = new() { Modifiers = 0x0002 | 0x0004, KeyCode = 0x20, DisplayName = "Ctrl + Shift + Space" };
    public static readonly HotkeyBinding DefaultPasteLastTranscript = new() { Modifiers = 0x0002 | 0x0004, KeyCode = 0x56, DisplayName = "Ctrl + Shift + V" };

    /// <summary>
    /// Migrate legacy settings fields into new provider configs.
    /// Called after deserialization.
    /// </summary>
    public void MigrateLegacySettings()
    {
        // Migrate old WhisperModel → SttProvider.Model
        if (!string.IsNullOrEmpty(WhisperModel) && SttProvider.Model == "whisper-1")
        {
            SttProvider.Model = WhisperModel;
            WhisperModel = null;
        }

        // Migrate old PostProcessModel → LlmProvider.Model
        if (!string.IsNullOrEmpty(PostProcessModel) && LlmProvider.Model == "gpt-4o-mini")
        {
            LlmProvider.Model = PostProcessModel;
            PostProcessModel = null;
        }

        // Migrate old SttProviderName → already "openai" by default, just clear
        if (!string.IsNullOrEmpty(SttProviderName))
        {
            SttProviderName = null;
        }
    }
}

/// <summary>
/// Well-known provider presets with default base URLs and display names.
/// </summary>
public static class ApiProviders
{
    public static readonly IReadOnlyList<ProviderPreset> SttPresets = new[]
    {
        new ProviderPreset("openai", "OpenAI", "https://api.openai.com/v1", new[] { "whisper-1", "gpt-4o-transcribe" }, SupportsStt: true, SupportsLlm: true),
        new ProviderPreset("groq", "Groq", "https://api.groq.com/openai/v1", new[] { "whisper-large-v3", "whisper-large-v3-turbo", "distil-whisper-large-v3-en" }, SupportsStt: true, SupportsLlm: true),
        new ProviderPreset("gemini", "Google Gemini", "https://generativelanguage.googleapis.com/v1beta/openai", new[] { "gemini-2.0-flash" }, SupportsStt: true, SupportsLlm: true),
        new ProviderPreset("custom", "Custom (OpenAI-compatible)", "", Array.Empty<string>(), SupportsStt: true, SupportsLlm: false),
    };

    public static readonly IReadOnlyList<ProviderPreset> LlmPresets = new[]
    {
        new ProviderPreset("openai", "OpenAI", "https://api.openai.com/v1", new[] { "gpt-4o-mini", "gpt-4.1-nano", "gpt-4.1-mini", "gpt-4o", "gpt-4.1", "o4-mini", "o3-mini" }, SupportsStt: true, SupportsLlm: true),
        new ProviderPreset("groq", "Groq", "https://api.groq.com/openai/v1", new[] { "llama-3.3-70b-versatile", "llama-3.1-8b-instant", "gemma2-9b-it", "mixtral-8x7b-32768" }, SupportsStt: true, SupportsLlm: true),
        new ProviderPreset("gemini", "Google Gemini", "https://generativelanguage.googleapis.com/v1beta/openai", new[] { "gemini-2.0-flash", "gemini-2.5-flash", "gemini-2.5-pro" }, SupportsStt: true, SupportsLlm: true),
        new ProviderPreset("deepseek", "DeepSeek", "https://api.deepseek.com/v1", new[] { "deepseek-chat", "deepseek-reasoner" }, SupportsStt: false, SupportsLlm: true),
        new ProviderPreset("openrouter", "OpenRouter", "https://openrouter.ai/api/v1", new[] { "openai/gpt-4o-mini", "anthropic/claude-3.5-sonnet", "google/gemini-2.0-flash-exp", "meta-llama/llama-3.3-70b-instruct" }, SupportsStt: false, SupportsLlm: true),
        new ProviderPreset("local", "Local (Ollama)", "http://localhost:11434/v1", new[] { "llama3.2", "mistral", "phi3" }, SupportsStt: false, SupportsLlm: true),
        new ProviderPreset("custom", "Custom (OpenAI-compatible)", "", Array.Empty<string>(), SupportsStt: false, SupportsLlm: true),
    };

    /// <summary>
    /// Get the default base URL for a provider type.
    /// </summary>
    public static string? GetDefaultBaseUrl(string providerType, bool isStt)
    {
        var presets = isStt ? SttPresets : LlmPresets;
        return presets.FirstOrDefault(p => p.Id == providerType)?.DefaultBaseUrl;
    }

    /// <summary>
    /// Get the effective base URL for a provider config (custom override or default).
    /// </summary>
    public static string GetEffectiveBaseUrl(ApiProviderConfig config, bool isStt)
    {
        if (!string.IsNullOrEmpty(config.BaseUrl))
            return config.BaseUrl;
        return GetDefaultBaseUrl(config.ProviderType, isStt) ?? "https://api.openai.com/v1";
    }

    /// <summary>
    /// Whether a provider type requires an API key (local providers typically don't).
    /// </summary>
    public static bool RequiresApiKey(string providerType) =>
        providerType != "local";
}

public record ProviderPreset(
    string Id,
    string DisplayName,
    string DefaultBaseUrl,
    string[] SuggestedModels,
    bool SupportsStt = false,
    bool SupportsLlm = false);
