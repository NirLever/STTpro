namespace STTpro.Core.Hotkeys;

public interface IGlobalHotkeyService : IDisposable
{
    void RegisterToggleRecording(uint modifiers, uint keyCode);
    void RegisterPasteLastTranscript(uint modifiers, uint keyCode);
    void StartHoldToTalkListening(uint modifiers, uint keyCode);
    void UnregisterAll();

    event EventHandler? ToggleRecordingPressed;
    event EventHandler? PasteLastTranscriptPressed;
    event EventHandler? HoldToTalkStarted;
    event EventHandler? HoldToTalkEnded;

    /// <summary>
    /// Fires when a prompt selection hotkey (Ctrl+Shift+1 through Ctrl+Shift+9) is pressed.
    /// The int argument is the prompt index (0-based).
    /// </summary>
    event EventHandler<int>? PromptSelected;

    /// <summary>
    /// Fires when a prompt hotkey is released (hold mode only).
    /// </summary>
    event EventHandler<int>? PromptReleased;

    void RegisterPromptHotkeys(IReadOnlyList<Settings.HotkeyBinding?> bindings);

    /// <summary>Temporarily pause all hotkey processing (for settings capture).</summary>
    void Pause();
    /// <summary>Resume hotkey processing after capture.</summary>
    void Resume();
}
