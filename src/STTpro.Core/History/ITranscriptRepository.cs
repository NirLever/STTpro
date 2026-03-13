namespace STTpro.Core.History;

public interface ITranscriptRepository
{
    Task EnsureCreatedAsync();
    Task<long> SaveAsync(TranscriptRecord record);
    Task<TranscriptRecord?> GetLatestAsync();
    Task<IReadOnlyList<TranscriptRecord>> GetRecentAsync(int count = 100, int offset = 0);
    Task<IReadOnlyList<TranscriptRecord>> SearchAsync(string query);
    Task DeleteAsync(long id);
    Task UpdateInsertionStatusAsync(long id, bool succeeded);
}
