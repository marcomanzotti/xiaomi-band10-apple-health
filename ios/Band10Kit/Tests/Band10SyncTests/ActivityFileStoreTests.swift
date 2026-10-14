import Band10Kit
import Foundation
import Testing
@testable import Band10Sync

@Suite("Activity file store")
struct ActivityFileStoreTests {
    private let store = ActivityFileStore(
        root: FileManager.default.temporaryDirectory.appendingPathComponent("band10-store-\(UUID().uuidString)")
    )

    /// A valid file: identifier, padding, one content byte and the CRC-32 of the rest.
    private func file(timestamp: UInt32) throws -> ActivityFile {
        let stamp = (0..<4).map { UInt8(truncatingIfNeeded: timestamp >> UInt32(8 * $0)) }
        let body = Data(stamp + [8, 5, 0x20, 0, 0x42])
        let crc = crc32(body)
        return try ActivityFile(raw: body + Data((0..<4).map { UInt8(truncatingIfNeeded: crc >> UInt32(8 * $0)) }))
    }

    private func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in
            (0..<8).reduce(crc ^ UInt32(byte)) { value, _ in value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
        }
    }

    @Test("returns saved files oldest first until they are marked as imported")
    func keepsPendingFiles() throws {
        let newer = try file(timestamp: 2000)
        let older = try file(timestamp: 1000)
        try store.save(newer)
        try store.save(older)

        #expect(try store.pendingFiles() == [older, newer])

        #expect(try store.markImported(older))

        #expect(try store.pendingFiles() == [newer])
    }

    @Test("saving the same file twice keeps one copy")
    func overwritesSameFile() throws {
        let saved = try file(timestamp: 1000)
        try store.save(saved)
        try store.save(saved)

        #expect(try store.pendingFiles().count == 1)
    }

    @Test("sets aside a damaged file instead of returning it")
    func setsAsideDamagedFile() throws {
        let pending = store.root.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: pending.appendingPathComponent("broken.bin"))

        #expect(try store.pendingFiles().isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("rejected/broken.bin").path))
    }

    @Test("deletes old imported files but never pending or rejected ones")
    func removesOnlyImportedFiles() throws {
        let imported = try file(timestamp: 1000)
        let pending = try file(timestamp: 2000)
        let rejected = try file(timestamp: 3000)
        try store.save(imported)
        try store.save(pending)
        try store.save(rejected)
        try store.markImported(imported)
        try store.markRejected(rejected.id)

        try store.removeImportedFiles(olderThan: Date().addingTimeInterval(60))

        #expect(try store.pendingFiles() == [pending])
        let importedFolder = store.root.appendingPathComponent("imported")
        #expect(try FileManager.default.contentsOfDirectory(atPath: importedFolder.path).isEmpty)
        let rejectedFolder = store.root.appendingPathComponent("rejected")
        #expect(try FileManager.default.contentsOfDirectory(atPath: rejectedFolder.path) == [rejected.id.filename])
    }

    @Test("leaves a file in the queue when a newer download replaced it during the import")
    func keepsReplacedFile() throws {
        let first = try file(timestamp: 1000)
        try store.save(first)
        let read = try #require(try store.pendingFiles().first)
        // Same identifier, longer content: today's file grew while Health was being written.
        let grown = try ActivityFile(raw: withCRC(Data(first.raw.dropLast(4)) + Data([0x43])))
        try store.save(grown)

        #expect(try store.markImported(read) == false)
        #expect(try store.pendingFiles() == [grown])
    }

    private func withCRC(_ body: Data) -> Data {
        let crc = crc32(body)
        return body + Data((0..<4).map { UInt8(truncatingIfNeeded: crc >> UInt32(8 * $0)) })
    }
}
