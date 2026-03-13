namespace STTpro.Core.Audio;

/// <summary>
/// Circular byte buffer that retains the last N milliseconds of audio data.
/// Thread-safe for single-writer, single-reader scenarios.
/// </summary>
public class PreRollRingBuffer
{
    private readonly byte[] _buffer;
    private int _writePos;
    private int _count;
    private readonly object _lock = new();

    public PreRollRingBuffer(int sampleRate, int bytesPerSample, int channels, int preRollMs)
    {
        int bytesPerMs = sampleRate * bytesPerSample * channels / 1000;
        _buffer = new byte[bytesPerMs * preRollMs];
    }

    public int Capacity => _buffer.Length;

    public void Write(byte[] data, int offset, int count)
    {
        lock (_lock)
        {
            int remaining = count;
            int srcPos = offset;
            while (remaining > 0)
            {
                int space = _buffer.Length - _writePos;
                int toCopy = Math.Min(remaining, space);
                Array.Copy(data, srcPos, _buffer, _writePos, toCopy);
                _writePos = (_writePos + toCopy) % _buffer.Length;
                srcPos += toCopy;
                remaining -= toCopy;
            }
            _count = Math.Min(_count + count, _buffer.Length);
        }
    }

    /// <summary>
    /// Returns all buffered data in chronological order and resets the buffer.
    /// </summary>
    public byte[] Flush()
    {
        lock (_lock)
        {
            if (_count == 0)
                return Array.Empty<byte>();

            var result = new byte[_count];

            if (_count < _buffer.Length)
            {
                // Buffer not full yet: data starts at 0
                int start = _writePos - _count;
                if (start < 0) start += _buffer.Length;

                if (start + _count <= _buffer.Length)
                {
                    Array.Copy(_buffer, start, result, 0, _count);
                }
                else
                {
                    int firstChunk = _buffer.Length - start;
                    Array.Copy(_buffer, start, result, 0, firstChunk);
                    Array.Copy(_buffer, 0, result, firstChunk, _count - firstChunk);
                }
            }
            else
            {
                // Buffer is full: data starts at _writePos
                int firstChunk = _buffer.Length - _writePos;
                Array.Copy(_buffer, _writePos, result, 0, firstChunk);
                Array.Copy(_buffer, 0, result, firstChunk, _writePos);
            }

            _count = 0;
            _writePos = 0;
            return result;
        }
    }

    public void Clear()
    {
        lock (_lock)
        {
            _count = 0;
            _writePos = 0;
        }
    }
}
