namespace STTpro.Core.Audio;

public record AudioDevice(int Index, string Name);

public interface IAudioCaptureService : IDisposable
{
    IReadOnlyList<AudioDevice> GetInputDevices();
    void SelectDevice(int deviceIndex);
    void StartListening();
    void StartRecording();
    Task<MemoryStream> StopRecordingAsync();
    void StopListening();
    event EventHandler<float>? LevelChanged;

    /// <summary>
    /// Splits the current recording: returns the audio recorded so far as a WAV stream,
    /// and starts a new segment without interrupting capture.
    /// Returns null if not currently recording or if there's insufficient audio.
    /// </summary>
    MemoryStream? SplitRecording();

    /// <summary>
    /// Fires when silence is detected during recording (for chunked transcription).
    /// </summary>
    event EventHandler? SilenceDetected;
}
