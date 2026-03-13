using STTpro.Core.Logging;
using STTpro.Core.Notifications;
using Forms = System.Windows.Forms;

namespace STTpro.App;

public class TrayNotificationService : INotificationService
{
    private Forms.NotifyIcon? _trayIcon;

    public void SetTrayIcon(Forms.NotifyIcon trayIcon)
    {
        _trayIcon = trayIcon;
    }

    public void ShowInfo(string message)
    {
        FileLogger.Info($"[Notification] {message}");
        ShowBalloon("STTpro", message, Forms.ToolTipIcon.Info);
    }

    public void ShowError(string message)
    {
        FileLogger.Error($"[Notification] {message}");
        ShowBalloon("STTpro Error", message, Forms.ToolTipIcon.Error);
    }

    public void ShowTranscriptionComplete(string text)
    {
        FileLogger.Info($"[Notification] Transcribed: {text}");
        var preview = text.Length > 80 ? text[..80] + "..." : text;
        ShowBalloon("STTpro - Transcribed", preview, Forms.ToolTipIcon.Info);
    }

    private void ShowBalloon(string title, string text, Forms.ToolTipIcon icon)
    {
        if (_trayIcon == null) return;

        try
        {
            Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                _trayIcon.ShowBalloonTip(3000, title, text, icon);
            });
        }
        catch
        {
            // Don't crash on notification failure
        }
    }
}
