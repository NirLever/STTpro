namespace STTpro.Core.Stt;

public record PostProcessResult(string Text, int InputTokens, int OutputTokens);

public interface IPostProcessor
{
    Task<PostProcessResult> ProcessAsync(
        string text,
        string systemPrompt,
        string model,
        CancellationToken ct = default);
}
