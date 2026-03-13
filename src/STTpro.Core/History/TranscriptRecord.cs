namespace STTpro.Core.History;

public class TranscriptRecord
{
    public long Id { get; set; }
    public DateTime Timestamp { get; set; }
    public string Text { get; set; } = "";
    public string DetectedLanguage { get; set; } = "";
    public double DurationSeconds { get; set; }
    public string ProviderName { get; set; } = "";
    public bool InsertionSucceeded { get; set; }
    public string TargetWindowName { get; set; } = "";
    /// <summary>Name of the smart prompt used, or empty if none.</summary>
    public string PromptName { get; set; } = "";
    /// <summary>Original transcription text before post-processing.</summary>
    public string OriginalText { get; set; } = "";
}
