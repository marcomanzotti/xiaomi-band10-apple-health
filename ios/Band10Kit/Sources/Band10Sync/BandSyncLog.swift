// Band10Sync — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.

import Foundation
import os

/// A short diary of what the sync did, kept in a file so that a problem that
/// happened in the background can be read afterwards. It never holds keys or
/// health values, only counts and states.
@MainActor
final class BandSyncLog {
    static let filename = "sync.log"
    private static let maximumLength = 200_000
    private static let recentLineCount = 40

    private let logger = Logger(subsystem: "band10sync", category: "sync")
    private let url: URL?
    private let formatter: DateFormatter
    private(set) var recentLines: [String] = []

    init(folder: URL?) {
        url = folder?.appendingPathComponent(Self.filename)
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss"
    }

    func add(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let line = "\(formatter.string(from: Date())) \(message)"
        recentLines = Array((recentLines + [line]).suffix(Self.recentLineCount))
        guard let url else { return }
        do {
            try append(line + "\n", to: url)
        } catch {
            logger.error("log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func append(_ text: String, to url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length > UInt64(Self.maximumLength) else {
            try handle.write(contentsOf: Data(text.utf8))
            return
        }
        // Keep the most recent half when the file grows too long.
        let recent = try Data(contentsOf: url).suffix(Self.maximumLength / 2)
        try (recent + Data(text.utf8)).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
