import Foundation
import os

/// Logs to the unified log (Console.app, subsystem "STTpro") and to
/// ~/Library/Logs/STTpro/sttpro.log. Never pass API keys or transcript text here.
public enum Log {
    private static let logger = Logger(subsystem: "STTpro", category: "app")
    private static let queue = DispatchQueue(label: "STTpro.log")

    public static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/STTpro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sttpro.log")
    }()

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO  \(message)")
    }

    public static func error(_ message: String, _ error: Error? = nil) {
        let full = error.map { "\(message): \($0.localizedDescription)" } ?? message
        logger.error("\(full, privacy: .public)")
        write("ERROR \(full)")
    }

    private static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        queue.async {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
