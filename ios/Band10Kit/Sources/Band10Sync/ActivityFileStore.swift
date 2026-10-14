// Band10Sync — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.

import Band10Kit
import Foundation

public enum ActivityFileStoreError: Error, Equatable, Sendable {
    case noApplicationSupportDirectory
}

/// Keeps the files downloaded from the band on disk until they are written to
/// Health. A file is acknowledged to the band only after it is saved here, so
/// nothing is lost if Health cannot be written at that moment (for example
/// while the phone is locked).
public struct ActivityFileStore: Sendable {
    private enum Folder: String, CaseIterable {
        /// Downloaded, not yet written to Health.
        case pending
        /// Written to Health; kept for a while to diagnose parsing problems.
        case imported
        /// Could not be read; kept so the format can be studied.
        case rejected
    }

    private static let folderName = "Band10Sync"
    private static let fileExtension = "bin"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The store inside the app's Application Support folder.
    public static func standard() throws -> ActivityFileStore {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ActivityFileStoreError.noApplicationSupportDirectory
        }
        return ActivityFileStore(root: support.appendingPathComponent(folderName, isDirectory: true))
    }

    public func save(_ file: ActivityFile) throws {
        let folder = try directory(.pending)
        // Readable while the phone is locked, once it has been unlocked after a restart.
        try file.raw.write(
            to: folder.appendingPathComponent(file.id.filename),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    /// Files waiting to be written to Health, oldest first. A file that can no
    /// longer be read is set aside instead of blocking the others.
    public func pendingFiles() throws -> [ActivityFile] {
        let folder = try directory(.pending)
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == Self.fileExtension }
        var files: [ActivityFile] = []
        for url in urls {
            if let file = try? ActivityFile(raw: try Data(contentsOf: url)) {
                files.append(file)
            } else {
                try move(url, to: .rejected)
            }
        }
        return files.sorted { ($0.id.timestamp, $0.id.filename) < ($1.id.timestamp, $1.id.filename) }
    }

    /// Moves the file out of the queue, unless a newer download replaced it on
    /// disk in the meantime: that one still has to be written. Returns whether it moved.
    @discardableResult
    public func markImported(_ file: ActivityFile) throws -> Bool {
        let url = try directory(.pending).appendingPathComponent(file.id.filename)
        guard (try? Data(contentsOf: url)) == file.raw else { return false }
        try move(url, to: .imported)
        return true
    }

    public func markRejected(_ id: ActivityFileID) throws {
        try move(try directory(.pending).appendingPathComponent(id.filename), to: .rejected)
    }

    /// Deletes imported files last touched before `date`. Pending and rejected
    /// files are never deleted: a rejected file may be the only copy of its data.
    public func removeImportedFiles(olderThan date: Date) throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: try directory(.imported), includingPropertiesForKeys: [.contentModificationDateKey]
        )
        for url in urls {
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, modified < date {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func move(_ url: URL, to folder: Folder) throws {
        let destination = try directory(folder).appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: url, to: destination)
    }

    private func directory(_ folder: Folder) throws -> URL {
        let url = root.appendingPathComponent(folder.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
