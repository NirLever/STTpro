using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;
using STTpro.Core.Logging;

namespace STTpro.Core.Stt;

public class WhisperApiProvider : ISttProvider
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private readonly HttpClient _httpClient;
    private readonly string _model;
    private readonly string _baseUrl;

    public string DisplayName => "OpenAI-compatible Whisper";

    public WhisperApiProvider(HttpClient httpClient, string model = "whisper-1", string baseUrl = "https://api.openai.com/v1")
    {
        _httpClient = httpClient;
        _model = model;
        _baseUrl = baseUrl.TrimEnd('/');
    }

    public async Task<SttResult> TranscribeAsync(
        Stream audioStream,
        string? languageHint = null,
        CancellationToken ct = default)
    {
        using var content = new MultipartFormDataContent();

        var audioContent = new StreamContent(audioStream);
        audioContent.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        content.Add(audioContent, "file", "audio.wav");
        content.Add(new StringContent(_model), "model");

        if (!string.IsNullOrEmpty(languageHint))
        {
            content.Add(new StringContent(languageHint), "language");
        }

        // Request verbose JSON to get language detection, duration, and no_speech_prob
        content.Add(new StringContent("verbose_json"), "response_format");

        var endpoint = $"{_baseUrl}/audio/transcriptions";
        FileLogger.Info($"Calling Whisper API: endpoint={endpoint}, model={_model}, language={languageHint ?? "auto"}");

        var response = await _httpClient.PostAsync(endpoint, content, ct);

        var json = await response.Content.ReadAsStringAsync(ct);
        FileLogger.Info($"Whisper API response status: {response.StatusCode}");
        FileLogger.Info($"Whisper API response body: {json}");

        response.EnsureSuccessStatusCode();

        var result = JsonSerializer.Deserialize<WhisperResponse>(json, JsonOptions);

        // Extract max no_speech_prob across all segments
        double noSpeechProb = 0;
        if (result?.Segments is { Count: > 0 })
        {
            noSpeechProb = result.Segments.Max(s => s.NoSpeechProb);
        }

        FileLogger.Info($"Whisper: no_speech_prob={noSpeechProb:F3}, duration={result?.Duration:F1}s");

        return new SttResult(
            Text: result?.Text?.Trim() ?? "",
            DetectedLanguage: result?.Language ?? "unknown",
            Duration: TimeSpan.FromSeconds(result?.Duration ?? 0),
            Confidence: 1.0,
            NoSpeechProbability: noSpeechProb);
    }

    private class WhisperResponse
    {
        public string? Text { get; set; }
        public string? Language { get; set; }
        public double? Duration { get; set; }
        public List<WhisperSegment>? Segments { get; set; }
    }

    private class WhisperSegment
    {
        [JsonPropertyName("no_speech_prob")]
        public double NoSpeechProb { get; set; }
    }
}
