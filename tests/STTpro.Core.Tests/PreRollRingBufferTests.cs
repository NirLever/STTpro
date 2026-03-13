using STTpro.Core.Audio;

namespace STTpro.Core.Tests;

public class PreRollRingBufferTests
{
    // 16kHz, 16-bit mono, 100ms buffer = 3200 bytes
    private PreRollRingBuffer CreateBuffer(int preRollMs = 100)
        => new(sampleRate: 16000, bytesPerSample: 2, channels: 1, preRollMs: preRollMs);

    [Fact]
    public void Capacity_IsCorrect()
    {
        var buffer = CreateBuffer(100);
        Assert.Equal(3200, buffer.Capacity); // 16000 * 2 * 1 / 1000 * 100
    }

    [Fact]
    public void Flush_WhenEmpty_ReturnsEmpty()
    {
        var buffer = CreateBuffer();
        var result = buffer.Flush();
        Assert.Empty(result);
    }

    [Fact]
    public void Write_ThenFlush_ReturnsWrittenData()
    {
        var buffer = CreateBuffer();
        var data = new byte[] { 1, 2, 3, 4, 5 };
        buffer.Write(data, 0, data.Length);

        var result = buffer.Flush();
        Assert.Equal(data, result);
    }

    [Fact]
    public void Flush_ClearsBuffer()
    {
        var buffer = CreateBuffer();
        buffer.Write(new byte[] { 1, 2, 3 }, 0, 3);
        buffer.Flush();

        var result = buffer.Flush();
        Assert.Empty(result);
    }

    [Fact]
    public void Write_OverCapacity_KeepsOnlyLatestData()
    {
        var buffer = CreateBuffer(100); // 3200 byte capacity

        // Write more than capacity
        var bigData = new byte[5000];
        for (int i = 0; i < bigData.Length; i++)
            bigData[i] = (byte)(i % 256);
        buffer.Write(bigData, 0, bigData.Length);

        var result = buffer.Flush();
        Assert.Equal(3200, result.Length);

        // Should contain the LAST 3200 bytes of the written data
        for (int i = 0; i < 3200; i++)
        {
            Assert.Equal(bigData[5000 - 3200 + i], result[i]);
        }
    }

    [Fact]
    public void MultipleWrites_FlushReturnsChronologicalOrder()
    {
        var buffer = CreateBuffer();

        buffer.Write(new byte[] { 10, 20, 30 }, 0, 3);
        buffer.Write(new byte[] { 40, 50 }, 0, 2);

        var result = buffer.Flush();
        Assert.Equal(new byte[] { 10, 20, 30, 40, 50 }, result);
    }

    [Fact]
    public void Clear_RemovesAllData()
    {
        var buffer = CreateBuffer();
        buffer.Write(new byte[] { 1, 2, 3 }, 0, 3);
        buffer.Clear();

        var result = buffer.Flush();
        Assert.Empty(result);
    }

    [Fact]
    public void WrapAround_DataIsCorrect()
    {
        // Small buffer for easy wrap testing
        var buffer = new PreRollRingBuffer(1000, 1, 1, 10); // 10 byte capacity

        // Fill to capacity
        buffer.Write(new byte[] { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, 0, 10);
        // Write 3 more, wrapping around
        buffer.Write(new byte[] { 11, 12, 13 }, 0, 3);

        var result = buffer.Flush();
        Assert.Equal(10, result.Length);
        // Should be 4,5,6,7,8,9,10,11,12,13
        Assert.Equal(new byte[] { 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }, result);
    }
}
