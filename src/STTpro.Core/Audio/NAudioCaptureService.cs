using NAudio.Wave;

namespace STTpro.Core.Audio;

public class NAudioCaptureService : IAudioCaptureService
{
    private const int SampleRate = 16000;
    private const int BitsPerSample = 16;
    private const int Channels = 1;
    private const int BytesPerSample = BitsPerSample / 8;

    private WaveInEvent? _waveIn;
    private PreRollRingBuffer? _preRollBuffer;
    private MemoryStream? _recordingStream;
    private BinaryWriter? _wavWriter;
    private bool _isRecording;
    private bool _isListening;
    private int _deviceIndex;
    private int _preRollMs = 300;
    private readonly SilenceDetector _silenceDetector;
    private readonly object _recordingLock = new();

    public event EventHandler<float>? LevelChanged;
    public event EventHandler? SilenceDetected;

    public NAudioCaptureService()
    {
        _silenceDetector = new SilenceDetector();
        _silenceDetector.SilenceDetected += (_, _) => SilenceDetected?.Invoke(this, EventArgs.Empty);
    }

    public void Configure(int preRollMs)
    {
        _preRollMs = preRollMs;
    }

    public IReadOnlyList<AudioDevice> GetInputDevices()
    {
        var devices = new List<AudioDevice>();
        for (int i = 0; i < WaveInEvent.DeviceCount; i++)
        {
            var caps = WaveInEvent.GetCapabilities(i);
            devices.Add(new AudioDevice(i, caps.ProductName));
        }
        return devices;
    }

    public void SelectDevice(int deviceIndex)
    {
        _deviceIndex = deviceIndex;
    }

    public void StartListening()
    {
        if (_isListening) return;

        _preRollBuffer = new PreRollRingBuffer(SampleRate, BytesPerSample, Channels, _preRollMs);

        _waveIn = new WaveInEvent
        {
            DeviceNumber = _deviceIndex,
            WaveFormat = new WaveFormat(SampleRate, BitsPerSample, Channels),
            BufferMilliseconds = 50
        };

        _waveIn.DataAvailable += OnDataAvailable;
        _waveIn.RecordingStopped += OnRecordingStopped;
        _waveIn.StartRecording();
        _isListening = true;
    }

    public void StartRecording()
    {
        if (!_isListening)
            StartListening();

        lock (_recordingLock)
        {
            _recordingStream = new MemoryStream();
            _wavWriter = new BinaryWriter(_recordingStream);

            // Write WAV header placeholder (will be finalized on stop)
            WriteWavHeader(_wavWriter, 0);

            // Flush pre-roll buffer as the beginning of the recording
            if (_preRollBuffer != null)
            {
                var preRoll = _preRollBuffer.Flush();
                if (preRoll.Length > 0)
                {
                    _wavWriter.Write(preRoll);
                }
            }

            _silenceDetector.Reset();
            _isRecording = true;
        }
    }

    public MemoryStream? SplitRecording()
    {
        lock (_recordingLock)
        {
            if (!_isRecording || _recordingStream == null || _wavWriter == null)
                return null;

            // Check if there's enough audio data (more than just the header + minimal data)
            if (_recordingStream.Position <= 44 + 3200) // ~100ms at 16kHz
                return null;

            // Finalize the current stream
            var completedStream = _recordingStream;
            var completedWriter = _wavWriter;

            long dataLength = completedStream.Position - 44;
            completedStream.Position = 0;
            WriteWavHeader(completedWriter, (int)dataLength);
            completedStream.Position = 0;

            // Start a new stream for the next segment
            _recordingStream = new MemoryStream();
            _wavWriter = new BinaryWriter(_recordingStream);
            WriteWavHeader(_wavWriter, 0);

            _silenceDetector.Reset();

            return completedStream;
        }
    }

    public Task<MemoryStream> StopRecordingAsync()
    {
        MemoryStream stream;

        lock (_recordingLock)
        {
            _isRecording = false;

            if (_recordingStream == null || _wavWriter == null)
                return Task.FromResult(new MemoryStream());

            stream = _recordingStream;
            var writer = _wavWriter;

            long dataLength = stream.Position - 44;
            stream.Position = 0;
            WriteWavHeader(writer, (int)dataLength);
            stream.Position = 0;

            _recordingStream = null;
            _wavWriter = null;
        }

        // Debug: save last recording in background (don't block transcription path)
        var debugCopy = new MemoryStream();
        stream.CopyTo(debugCopy);
        stream.Position = 0;
        debugCopy.Position = 0;
        _ = Task.Run(() =>
        {
            try
            {
                var debugDir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "STTpro");
                var debugPath = Path.Combine(debugDir, "last_recording.wav");
                using var fs = File.Create(debugPath);
                debugCopy.CopyTo(fs);
            }
            catch { /* ignore */ }
            finally { debugCopy.Dispose(); }
        });

        return Task.FromResult(stream);
    }

    public void StopListening()
    {
        _isListening = false;
        _isRecording = false;

        if (_waveIn != null)
        {
            _waveIn.DataAvailable -= OnDataAvailable;
            _waveIn.RecordingStopped -= OnRecordingStopped;
            _waveIn.StopRecording();
            _waveIn.Dispose();
            _waveIn = null;
        }

        _preRollBuffer?.Clear();
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        // Calculate audio level for UI
        float max = 0;
        for (int i = 0; i < e.BytesRecorded - 1; i += 2)
        {
            short sample = (short)(e.Buffer[i] | (e.Buffer[i + 1] << 8));
            float abs = Math.Abs(sample / 32768f);
            if (abs > max) max = abs;
        }
        LevelChanged?.Invoke(this, max);

        lock (_recordingLock)
        {
            if (_isRecording && _wavWriter != null)
            {
                _wavWriter.Write(e.Buffer, 0, e.BytesRecorded);

                // Feed silence detector
                _silenceDetector.Process(e.Buffer, 0, e.BytesRecorded);
            }
            else
            {
                // Fill pre-roll buffer
                _preRollBuffer?.Write(e.Buffer, 0, e.BytesRecorded);
            }
        }
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        if (e.Exception != null)
        {
            _isListening = false;
            _isRecording = false;
        }
    }

    private static void WriteWavHeader(BinaryWriter writer, int dataLength)
    {
        writer.Write("RIFF"u8);
        writer.Write(36 + dataLength);
        writer.Write("WAVE"u8);
        writer.Write("fmt "u8);
        writer.Write(16);                         // Sub-chunk size
        writer.Write((short)1);                   // PCM
        writer.Write((short)Channels);
        writer.Write(SampleRate);
        writer.Write(SampleRate * Channels * BytesPerSample); // Byte rate
        writer.Write((short)(Channels * BytesPerSample));     // Block align
        writer.Write((short)BitsPerSample);
        writer.Write("data"u8);
        writer.Write(dataLength);
    }

    public void Dispose()
    {
        StopListening();
        _recordingStream?.Dispose();
    }
}
