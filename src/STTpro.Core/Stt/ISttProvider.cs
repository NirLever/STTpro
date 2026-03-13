namespace STTpro.Core.Stt;

public interface ISttProvider
{
    string DisplayName { get; }

    Task<SttResult> TranscribeAsync(
        Stream audioStream,
        string? languageHint = null,
        CancellationToken ct = default);
}
