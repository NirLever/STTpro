import Foundation
import SQLite3

public struct TranscriptRecord: Identifiable, Equatable {
    public var id: Int64 = 0
    public var timestamp: Date = Date()
    public var text: String = ""
    public var detectedLanguage: String = ""
    public var durationSeconds: Double = 0
    public var providerName: String = ""
    public var insertionSucceeded: Bool = false
    /// Name of the app that was frontmost when recording started.
    public var targetWindowName: String = ""
    public var promptName: String = ""
    /// Text before Smart Prompt post-processing.
    public var originalText: String = ""

    public init(id: Int64 = 0, timestamp: Date = Date(), text: String = "", detectedLanguage: String = "",
                durationSeconds: Double = 0, providerName: String = "", insertionSucceeded: Bool = false,
                targetWindowName: String = "", promptName: String = "", originalText: String = "") {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.durationSeconds = durationSeconds
        self.providerName = providerName
        self.insertionSucceeded = insertionSucceeded
        self.targetWindowName = targetWindowName
        self.promptName = promptName
        self.originalText = originalText
    }
}

/// Local SQLite history, same schema as the Windows SqliteTranscriptRepository.
public final class HistoryStore: @unchecked Sendable {
    public let url: URL
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw NSError(domain: "STTpro.History", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        try exec("""
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
            CREATE INDEX IF NOT EXISTS idx_transcripts_timestamp ON transcripts(timestamp DESC);
            """)
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(err)
            throw NSError(domain: "STTpro.History", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.error("SQLite prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
        sqlite3_bind_text(stmt, index, text, -1, Self.transient)
    }

    @discardableResult
    public func save(_ r: TranscriptRecord) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare("""
            INSERT INTO transcripts (timestamp, text, detected_lang, duration_sec, provider, insertion_ok, target_window, prompt_name, original_text)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Self.isoFormatter.string(from: r.timestamp))
        bind(stmt, 2, r.text)
        bind(stmt, 3, r.detectedLanguage)
        sqlite3_bind_double(stmt, 4, r.durationSeconds)
        bind(stmt, 5, r.providerName)
        sqlite3_bind_int(stmt, 6, r.insertionSucceeded ? 1 : 0)
        bind(stmt, 7, r.targetWindowName)
        bind(stmt, 8, r.promptName)
        bind(stmt, 9, r.originalText)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            Log.error("SQLite insert failed: \(String(cString: sqlite3_errmsg(db)))")
            return 0
        }
        return sqlite3_last_insert_rowid(db)
    }

    public func latest() -> TranscriptRecord? {
        query("SELECT * FROM transcripts WHERE text NOT LIKE '[Transcription failed%' ORDER BY id DESC LIMIT 1").first
    }

    public func recent(limit: Int = 200, offset: Int = 0) -> [TranscriptRecord] {
        query("SELECT * FROM transcripts ORDER BY id DESC LIMIT ? OFFSET ?") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
            sqlite3_bind_int(stmt, 2, Int32(offset))
        }
    }

    public func search(_ text: String, limit: Int = 200) -> [TranscriptRecord] {
        query("SELECT * FROM transcripts WHERE text LIKE ? OR original_text LIKE ? ORDER BY id DESC LIMIT ?") { stmt in
            self.bind(stmt, 1, "%\(text)%")
            self.bind(stmt, 2, "%\(text)%")
            sqlite3_bind_int(stmt, 3, Int32(limit))
        }
    }

    public func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare("SELECT COUNT(*) FROM transcripts") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    public func delete(id: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare("DELETE FROM transcripts WHERE id = ?") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
    }

    public func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        try? exec("DELETE FROM transcripts")
    }

    /// Keeps only the newest `max` rows (0 = unlimited).
    public func prune(keeping max: Int) {
        guard max > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare("DELETE FROM transcripts WHERE id NOT IN (SELECT id FROM transcripts ORDER BY id DESC LIMIT ?)") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(max))
        sqlite3_step(stmt)
    }

    private func query(_ sql: String, bindings: ((OpaquePointer?) -> Void)? = nil) -> [TranscriptRecord] {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindings?(stmt)

        var columns: [String: Int32] = [:]
        for i in 0..<sqlite3_column_count(stmt) {
            columns[String(cString: sqlite3_column_name(stmt, i))] = i
        }
        func text(_ name: String) -> String {
            guard let i = columns[name], let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }
        func double(_ name: String) -> Double { columns[name].map { sqlite3_column_double(stmt, $0) } ?? 0 }
        func int(_ name: String) -> Int64 { columns[name].map { sqlite3_column_int64(stmt, $0) } ?? 0 }

        var out: [TranscriptRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = text("timestamp")
            out.append(TranscriptRecord(
                id: int("id"),
                timestamp: Self.isoFormatter.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) ?? Date(timeIntervalSince1970: 0),
                text: text("text"),
                detectedLanguage: text("detected_lang"),
                durationSeconds: double("duration_sec"),
                providerName: text("provider"),
                insertionSucceeded: int("insertion_ok") == 1,
                targetWindowName: text("target_window"),
                promptName: text("prompt_name"),
                originalText: text("original_text")))
        }
        return out
    }
}
