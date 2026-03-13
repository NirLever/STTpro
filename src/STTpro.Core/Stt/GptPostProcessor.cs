using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using STTpro.Core.Logging;
using STTpro.Core.Security;
using STTpro.Core.Settings;

namespace STTpro.Core.Stt;

/// <summary>
/// Post-processor that uses any OpenAI-compatible chat completions API.
/// Works with OpenAI, Groq, DeepSeek, OpenRouter, Ollama, LM Studio, etc.
/// </summary>
public class GptPostProcessor : IPostProcessor
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private readonly DpapiCredentialStore _credentialStore;
    private readonly ISettingsService _settings;
    private HttpClient? _cachedClient;
    private string _cachedClientKey = "";

    public GptPostProcessor(DpapiCredentialStore credentialStore, ISettingsService settings)
    {
        _credentialStore = credentialStore;
        _settings = settings;
    }

    /// <summary>Clear cached HttpClient (call when API keys or provider settings change).</summary>
    public void ClearCache()
    {
        _cachedClient?.Dispose();
        _cachedClient = null;
        _cachedClientKey = "";
    }

    public async Task<PostProcessResult> ProcessAsync(
        string text,
        string systemPrompt,
        string model,
        CancellationToken ct = default)
    {
        var config = _settings.Current.LlmProvider;
        var baseUrl = ApiProviders.GetEffectiveBaseUrl(config, isStt: false).TrimEnd('/');
        var apiKeySlot = _settings.Current.UseSharedApiKey
            ? _settings.Current.SttProvider.ApiKeySlot
            : config.ApiKeySlot;

        // Reuse HttpClient for same provider configuration
        var clientKey = $"{config.ProviderType}:{apiKeySlot}:{baseUrl}";
        if (_cachedClient == null || _cachedClientKey != clientKey)
        {
            _cachedClient?.Dispose();
            _cachedClient = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            _cachedClientKey = clientKey;

            if (ApiProviders.RequiresApiKey(config.ProviderType))
            {
                var apiKey = _credentialStore.LoadApiKey(apiKeySlot)
                    ?? throw new InvalidOperationException(
                        $"No API key configured for {config.ProviderType}. Please set your API key in Settings.");

                _cachedClient.DefaultRequestHeaders.Authorization =
                    new AuthenticationHeaderValue("Bearer", apiKey);
            }
        }

        var httpClient = _cachedClient!;

        var requestBody = new
        {
            model,
            messages = new[]
            {
                new { role = "system", content = systemPrompt },
                new { role = "user", content = text }
            },
            temperature = 0.3
        };

        var json = JsonSerializer.Serialize(requestBody);
        var content = new StringContent(json, Encoding.UTF8, "application/json");

        var endpoint = $"{baseUrl}/chat/completions";
        FileLogger.Info($"Post-process: endpoint={endpoint}, model={model}, prompt length={systemPrompt.Length}, text length={text.Length}");

        var response = await httpClient.PostAsync(endpoint, content, ct);

        var responseJson = await response.Content.ReadAsStringAsync(ct);
        FileLogger.Info($"Post-process response status: {response.StatusCode}");

        response.EnsureSuccessStatusCode();

        var result = JsonSerializer.Deserialize<ChatCompletionResponse>(responseJson, JsonOptions);

        var outputText = result?.Choices?.FirstOrDefault()?.Message?.Content?.Trim() ?? text;
        int inputTokens = result?.Usage?.PromptTokens ?? 0;
        int outputTokens = result?.Usage?.CompletionTokens ?? 0;

        FileLogger.Info($"Post-process done: {inputTokens} in, {outputTokens} out, result length={outputText.Length}");

        return new PostProcessResult(outputText, inputTokens, outputTokens);
    }

    // Response models (OpenAI-compatible format)
    private class ChatCompletionResponse
    {
        public List<Choice>? Choices { get; set; }
        public UsageInfo? Usage { get; set; }
    }

    private class Choice
    {
        public MessageContent? Message { get; set; }
    }

    private class MessageContent
    {
        public string? Content { get; set; }
    }

    private class UsageInfo
    {
        public int PromptTokens { get; set; }
        public int CompletionTokens { get; set; }
        public int TotalTokens { get; set; }
    }
}
