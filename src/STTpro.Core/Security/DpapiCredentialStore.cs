using System.Security.Cryptography;
using System.Text;

namespace STTpro.Core.Security;

public class DpapiCredentialStore
{
    private readonly string _credentialsDir;
    private readonly string _legacyCredentialsPath;

    public DpapiCredentialStore()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        _credentialsDir = Path.Combine(appData, "STTpro");
        Directory.CreateDirectory(_credentialsDir);
        _legacyCredentialsPath = Path.Combine(_credentialsDir, ".credentials");
    }

    /// <summary>
    /// Save an API key for a named slot (e.g., "openai", "groq", "anthropic").
    /// </summary>
    public void SaveApiKey(string key, string slot = "default")
    {
        var plainBytes = Encoding.UTF8.GetBytes(key);
        var encryptedBytes = ProtectedData.Protect(plainBytes, null, DataProtectionScope.CurrentUser);
        var path = GetSlotPath(slot);
        File.WriteAllText(path, Convert.ToBase64String(encryptedBytes));
    }

    /// <summary>
    /// Load an API key from a named slot. Falls back to legacy single-key file for "default" slot.
    /// </summary>
    public string? LoadApiKey(string slot = "default")
    {
        var path = GetSlotPath(slot);

        // For "default" slot, try the new path first, then fall back to legacy
        if (!File.Exists(path) && slot == "default" && File.Exists(_legacyCredentialsPath))
            path = _legacyCredentialsPath;

        if (!File.Exists(path))
            return null;

        try
        {
            var base64 = File.ReadAllText(path);
            var encryptedBytes = Convert.FromBase64String(base64);
            var plainBytes = ProtectedData.Unprotect(encryptedBytes, null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plainBytes);
        }
        catch
        {
            return null;
        }
    }

    public bool HasApiKey(string slot = "default")
    {
        if (File.Exists(GetSlotPath(slot)))
            return true;
        // Legacy fallback for default slot
        if (slot == "default" && File.Exists(_legacyCredentialsPath))
            return true;
        return false;
    }

    public void DeleteApiKey(string slot = "default")
    {
        var path = GetSlotPath(slot);
        if (File.Exists(path))
            File.Delete(path);
        // Also clean up legacy file for default slot
        if (slot == "default" && File.Exists(_legacyCredentialsPath))
            File.Delete(_legacyCredentialsPath);
    }

    // Backward-compatible overloads (no slot parameter = "default")
    public void SaveApiKey(string key) => SaveApiKey(key, "default");
    public string? LoadApiKey() => LoadApiKey("default");
    public bool HasApiKey() => HasApiKey("default");
    public void DeleteApiKey() => DeleteApiKey("default");

    private string GetSlotPath(string slot)
    {
        // Sanitize slot name for filesystem
        var safeName = slot.Replace('/', '_').Replace('\\', '_').Replace(':', '_');
        return slot == "default"
            ? Path.Combine(_credentialsDir, ".credentials")
            : Path.Combine(_credentialsDir, $".credentials_{safeName}");
    }
}
