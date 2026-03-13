namespace STTpro.Core.Audio;

/// <summary>
/// Detects silence periods in 16-bit PCM audio data.
/// Used to find good split points for chunked transcription.
/// </summary>
public class SilenceDetector
{
    private readonly float _silenceThreshold;
    private readonly int _silenceDurationMs;
    private readonly int _sampleRate;
    private readonly int _bytesPerSample;

    private int _silenceSampleCount;
    private int _totalSampleCount;

    /// <summary>Fires when a silence period long enough for a split is detected.</summary>
    public event EventHandler? SilenceDetected;

    public SilenceDetector(
        float silenceThreshold = 0.01f,
        int silenceDurationMs = 700,
        int sampleRate = 16000,
        int bytesPerSample = 2)
    {
        _silenceThreshold = silenceThreshold;
        _silenceDurationMs = silenceDurationMs;
        _sampleRate = sampleRate;
        _bytesPerSample = bytesPerSample;
    }

    /// <summary>
    /// Process a chunk of audio data. Call this with each buffer from the microphone.
    /// </summary>
    public void Process(byte[] buffer, int offset, int count)
    {
        int samplesInBuffer = count / _bytesPerSample;
        _totalSampleCount += samplesInBuffer;

        // Don't split if less than 5 seconds of audio recorded
        int minSamplesBeforeSplit = _sampleRate * 5;
        if (_totalSampleCount < minSamplesBeforeSplit)
            return;

        // Check if the buffer is mostly silence
        float maxLevel = 0;
        for (int i = offset; i < offset + count - 1; i += _bytesPerSample)
        {
            short sample = (short)(buffer[i] | (buffer[i + 1] << 8));
            float abs = Math.Abs(sample / 32768f);
            if (abs > maxLevel) maxLevel = abs;
        }

        if (maxLevel < _silenceThreshold)
        {
            _silenceSampleCount += samplesInBuffer;

            int silenceSamplesRequired = _sampleRate * _silenceDurationMs / 1000;
            if (_silenceSampleCount >= silenceSamplesRequired)
            {
                _silenceSampleCount = 0;
                _totalSampleCount = 0;
                SilenceDetected?.Invoke(this, EventArgs.Empty);
            }
        }
        else
        {
            _silenceSampleCount = 0;
        }
    }

    public void Reset()
    {
        _silenceSampleCount = 0;
        _totalSampleCount = 0;
    }
}
