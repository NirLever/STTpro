namespace STTpro.Core.Notifications;

public interface INotificationService
{
    void ShowInfo(string message);
    void ShowError(string message);
    void ShowTranscriptionComplete(string text);
}
