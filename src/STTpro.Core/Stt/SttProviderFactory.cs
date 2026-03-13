using System.Collections.Concurrent;
using System.Net.Http.Headers;
using STTpro.Core.Security;
using STTpro.Core.Settings;

namespace STTpro.Core.Stt;

public class SttProviderFactory
{
    private readonly DpapiCredentialStore _credentialStore;
    private readonly ISettingsService _settings;

    // Cache HttpClient per (providerType, apiKeySlot, baseUrl) to reuse TCP connections
    private readonly ConcurrentDictionary<string, HttpClient> _httpClientCache = new();

    public SttProviderFactory(DpapiCredentialStore credentialStore, ISettingsService settings)
    {
        _credentialStore = credentialStore;
        _settings = settings;
    }

    /// <summary>
    /// Create an STT provider using the current settings configuration.
    /// </summary>
    public ISttProvider Create()
    {
        var config = _settings.Current.SttProvider;
        return CreateFromConfig(config);
    }

    /// <summary>
    /// Create an STT provider from explicit config (used for chunk transcription
    /// where config is captured at recording start).
    /// </summary>
    public ISttProvider CreateFromConfig(ApiProviderConfig config)
    {
        var baseUrl = ApiProviders.GetEffectiveBaseUrl(config, isStt: true);
        var cacheKey = $"stt:{config.ProviderType}:{config.ApiKeySlot}:{baseUrl}";

        var httpClient = _httpClientCache.GetOrAdd(cacheKey, _ =>
        {
            var client = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };

            if (ApiProviders.RequiresApiKey(config.ProviderType))
            {
                var apiKey = _credentialStore.LoadApiKey(config.ApiKeySlot)
                    ?? throw new InvalidOperationException(
                        $"No API key configured for {config.ProviderType}. Please set your API key in Settings.");

                client.DefaultRequestHeaders.Authorization =
                    new AuthenticationHeaderValue("Bearer", apiKey);
            }

            return client;
        });

        return new WhisperApiProvider(httpClient, config.Model, baseUrl);
    }

    /// <summary>
    /// Clear cached HttpClients (call when API keys change).
    /// </summary>
    public void ClearCache()
    {
        foreach (var client in _httpClientCache.Values)
            client.Dispose();
        _httpClientCache.Clear();
    }
}
