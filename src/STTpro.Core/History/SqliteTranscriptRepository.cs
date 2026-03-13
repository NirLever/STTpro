using Microsoft.Data.Sqlite;

namespace STTpro.Core.History;

public class SqliteTranscriptRepository : ITranscriptRepository
{
    private readonly string _connectionString;

    public SqliteTranscriptRepository()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var dir = Path.Combine(appData, "STTpro");
        Directory.CreateDirectory(dir);
        var dbPath = Path.Combine(dir, "history.db");
        _connectionString = $"Data Source={dbPath}";
    }

    public async Task EnsureCreatedAsync()
    {
        await using var conn = new SqliteConnection(_connectionString);
        await conn.OpenAsync();

        var cmd = conn.CreateCommand();
        cmd.CommandText = """
            CREATE TABLE IF NOT EXISTS transcripts (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp       TEXT NOT NULL,
                text            TEXT NOT NULL,
                detected_lang   TEXT NOT NULL DEFAULT '',
                duration_sec    REAL NOT NULL DEFAULT 0,
                provider        TEXT NOT NULL DEFAULT '',
                insertion_ok    INTEGER NOT NULL DEFAULT 0,
                target_window   TEXT NOT NULL DEFAULT '',
                prompt_name     TEXT NOT NULL DEFAULT '',
                original_text   TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS idx_transcripts_timestamp
                ON transcripts(timestamp DESC);
            """;
        await cmd.ExecuteNonQueryAsync();

        // Add columns if upgrading from older schema
        var alter = conn.CreateCommand();
        alter.CommandText = """
            ALTER TABLE transcripts ADD COLUMN prompt_name TEXT NOT NULL DEFAULT '';
            """;
        try { await alter.ExecuteNonQueryAsync(); } catch { /* column already exists */ }
        var alter2 = conn.CreateCommand();
        alter2.CommandText = """
            ALTER TABLE transcripts ADD COLUMN original_text TEXT NOT NULL DEFAULT '';
            """;
        try { await alter2.ExecuteNonQueryAsync(); } catch { /* column already exists */ }
        await cmd.ExecuteNonQueryAsync();
    }

    public async Task<long> SaveAsync(TranscriptRecord record)
    {
        await using var conn = new SqliteConnection(_connectionString);
        await conn.OpenAsync();

        var cmd = conn.CreateCommand();
        cmd.CommandText = """
            INSERT INTO transcripts (timestamp, text, detected_lang, duration_sec, provider, insertion_ok, target_window, prompt_name, original_text)
            VALUES ($ts, $text, $lang, $dur, $prov, $ok, $win, $prompt, $orig);
            SELECT last_insert_rowid();
            """;
        cmd.Parameters.AddWithValue("$ts", record.Timestamp.ToString("O"));
        cmd.Parameters.AddWithValue("$text", record.Text);
        cmd.Parameters.AddWithValue("$lang", record.DetectedLanguage);
        cmd.Parameters.AddWithValue("$dur", record.DurationSeconds);
        cmd.Parameters.AddWithValue("$prov", record.ProviderName);
        cmd.Parameters.AddWithValue("$ok", record.InsertionSucceeded ? 1 : 0);
        cmd.Parameters.AddWithValue("$win", record.TargetWindowName);
        cmd.Parameters.AddWithValue("$prompt", record.PromptName);
        cmd.Parameters.AddWithValue("$orig", record.OriginalText);

        var result = await cmd.ExecuteScalarAsync();
        return (long)result!;
    }

    public async Task<TranscriptRecord?> GetLatestAsync()
    {
        await using var conn = new SqliteConnection(_connectionString);
        await conn.OpenAsync();

        var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT * FROM transcripts ORDER BY id DESC LIMIT 1";

        await using var reader = await cmd.ExecuteReaderAsync();
        if (await reader.ReadAsync())
            return ReadRecord(reader);

        return null;
    }

    public async Task<IReadOnlyList<TranscriptRecord>> GetRecentAsync(int count = 100, int offset = 0)
    {
        await using var conn = new SqliteConnection(_connectionString);
        await conn.OpenAsync();

        var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT * FROM transcripts ORDER BY id DESC LIMIT $limit OFFSET $offset";
        cmd.Parameters.AddWithValue("$limit", count);
        cmd.Parameters.AddWithValue("$offset", offset);

        var records = new List<TranscriptRecord>();
        await using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
            records.Add(ReadRecord(reader));

        return records;
    }

    public async Task<IReadOnlyList<TranscriptRecord>> SearchAsync(string query)
    {
        await using var conn = new SqliteConnection(_connectionString);
        await conn.OpenAsync();

        var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT * FROM transcripts WHERE text LIKE $q ORDER BY id DESC LIMIT 100";
        cmd.Parameters.AddWithValue("$q", $"%{query}%");

        var records = new List<TranscriptRecord>();
        await using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
            records.Add(ReadRecord(reader));

        return records;
    }

    public async Task DeleteAsync(long id)
    {
        await using var conn = new SqliteConnection(_connectionString);
        await conn.OpenAsync();

        var cmd = conn.CreateCommand();
        cmd.CommandText = "DELETE FROM transcripts WHERE id = $id";
        cmd.Parameters.AddWithValue("$id", id);
        await cmd.ExecuteNonQueryAsync();
    }

    public async Task UpdateInsertionStatusAsync(long id, bool succeeded)
    {
        await using var conn = new SqliteConnection(_connectionString);
        await conn.OpenAsync();

        var cmd = conn.CreateCommand();
        cmd.CommandText = "UPDATE transcripts SET insertion_ok = $ok WHERE id = $id";
        cmd.Parameters.AddWithValue("$ok", succeeded ? 1 : 0);
        cmd.Parameters.AddWithValue("$id", id);
        await cmd.ExecuteNonQueryAsync();
    }

    private static TranscriptRecord ReadRecord(SqliteDataReader reader)
    {
        var record = new TranscriptRecord
        {
            Id = reader.GetInt64(reader.GetOrdinal("id")),
            Timestamp = DateTime.Parse(reader.GetString(reader.GetOrdinal("timestamp"))),
            Text = reader.GetString(reader.GetOrdinal("text")),
            DetectedLanguage = reader.GetString(reader.GetOrdinal("detected_lang")),
            DurationSeconds = reader.GetDouble(reader.GetOrdinal("duration_sec")),
            ProviderName = reader.GetString(reader.GetOrdinal("provider")),
            InsertionSucceeded = reader.GetInt32(reader.GetOrdinal("insertion_ok")) == 1,
            TargetWindowName = reader.GetString(reader.GetOrdinal("target_window"))
        };
        // Safe read for new columns (may not exist in older DBs before ALTER)
        try { record.PromptName = reader.GetString(reader.GetOrdinal("prompt_name")); } catch { }
        try { record.OriginalText = reader.GetString(reader.GetOrdinal("original_text")); } catch { }
        return record;
    }
}
