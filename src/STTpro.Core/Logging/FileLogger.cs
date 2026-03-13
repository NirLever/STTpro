namespace STTpro.Core.Logging;

public static class FileLogger
{
    private static readonly string LogPath;
    private static readonly object Lock = new();

    static FileLogger()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var dir = Path.Combine(appData, "STTpro");
        Directory.CreateDirectory(dir);
        LogPath = Path.Combine(dir, "sttpro.log");
    }

    public static void Log(string level, string message)
    {
        var line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] [{level}] {message}";
        lock (Lock)
        {
            try
            {
                File.AppendAllText(LogPath, line + Environment.NewLine);
            }
            catch { /* don't crash on log failure */ }
        }
    }

    public static void Info(string message) => Log("INFO", message);
    public static void Error(string message) => Log("ERROR", message);
    public static void Error(string message, Exception ex) => Log("ERROR", $"{message}: {ex}");
}
