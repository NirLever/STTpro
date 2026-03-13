namespace STTpro.Core.Output;

public enum OutputMode
{
    DirectTyping,
    ClipboardPaste,
    CopyOnly,
    SaveOnly
}

public interface ITextOutputService
{
    Task InsertTextAsync(string text, OutputMode mode);
}
