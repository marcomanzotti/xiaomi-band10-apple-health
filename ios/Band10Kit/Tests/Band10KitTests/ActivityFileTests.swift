import Foundation
import Testing
@testable import Band10Kit

// File layouts follow Gadgetbridge's activity parsers; the fixtures are built
// by hand from those layouts, not captured from a band.

/// Wraps content the way the band does: identifier, padding, content, CRC-32.
func makeActivityFile(_ id: ActivityFileID, content: Data) throws -> ActivityFile {
    let body = id.encoded() + Data([0]) + content
    let crc = CRC32.checksum(body)
    return try ActivityFile(raw: body + Data((0..<4).map { UInt8(truncatingIfNeeded: crc >> UInt32(8 * $0)) }))
}

func activityID(_ flags: UInt8, version: UInt8, timestamp: UInt32 = 1_700_000_000) throws -> ActivityFileID {
    let stamp = (0..<4).map { UInt8(truncatingIfNeeded: timestamp >> UInt32(8 * $0)) }
    return try ActivityFileID(decoding: Data(stamp + [8, version, flags]))
}

enum FileFlags {
    static let dailyDetails: UInt8 = 0x00
    static let dailySummary: UInt8 = 0x01
    static let sleepStages: UInt8 = 0x0C
    static let manualSamples: UInt8 = 0x18
    static let sleep: UInt8 = 0x20
    static let workoutSummary: UInt8 = 0xA1
}

@Suite("Activity file identifiers")
struct ActivityFileIDTests {
    @Test("reads timestamp, timezone, version and the three parts of the flags byte")
    func decodesIdentifier() throws {
        let id = try ActivityFileID(decoding: Data(hex: "8a90a965" + "08" + "05" + "a1"))

        #expect(id.timestamp == 0x65A9_908A)
        #expect(id.timezone == 8)
        #expect(id.version == 5)
        #expect(id.category == 1)
        #expect(id.subtype == 8)
        #expect(id.detail == 1)
    }

    @Test("encodes back to the same seven bytes")
    func roundTrips() throws {
        let bytes = Data(hex: "8a90a965f80320")

        #expect(try ActivityFileID(decoding: bytes).encoded() == bytes)
    }

    @Test("names the kind of data a file holds", arguments: [
        (FileFlags.dailyDetails, ActivityFileID.Kind.dailyDetails),
        (FileFlags.dailySummary, .dailySummary),
        (FileFlags.sleepStages, .sleepStages),
        (FileFlags.manualSamples, .manualSamples),
        (FileFlags.sleep, .sleep),
        (FileFlags.workoutSummary, .workout),
        (0x10, .unknown),
    ])
    func classifies(flags: UInt8, kind: ActivityFileID.Kind) throws {
        #expect(try activityID(flags, version: 1).kind == kind)
    }

    @Test("splits a list of identifiers and drops all-zero padding entries")
    func decodesList() throws {
        let first = Data(hex: "8a90a965080300")
        let list = first + Data(count: 7) + Data(hex: "8b90a965080520")

        let ids = try ActivityFileID.list(decoding: list)

        #expect(ids.map(\.kind) == [.dailyDetails, .sleep])
        #expect(ids.first?.encoded() == first)
    }

    @Test("rejects a list whose length is not a whole number of identifiers")
    func rejectsRaggedList() {
        #expect(throws: ActivityParseError.self) {
            try ActivityFileID.list(decoding: Data(count: 8))
        }
    }
}

@Suite("Activity file assembly")
struct ActivityFileAssemblerTests {
    private func pieces(of file: ActivityFile, size: Int) -> [Data] {
        let chunks = stride(from: 0, to: file.raw.count, by: size).map {
            file.raw.subdata(in: $0..<min($0 + size, file.raw.count))
        }
        return chunks.enumerated().map { index, chunk in
            Data([UInt8(chunks.count), 0, UInt8(index + 1), 0]) + chunk
        }
    }

    @Test("computes the standard CRC-32")
    func checksumMatchesReferenceVector() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test("joins numbered pieces into a checked file")
    func assemblesPieces() throws {
        let file = try makeActivityFile(try activityID(FileFlags.sleep, version: 5), content: Data(repeating: 0xAB, count: 20))
        var assembler = ActivityFileAssembler()
        let parts = pieces(of: file, size: 12)

        let outcomes = parts.map { assembler.append($0) }

        #expect(outcomes.dropLast().allSatisfy { if case .incomplete = $0 { true } else { false } })
        #expect(outcomes.last == .complete(file))
        #expect(file.content == Data(repeating: 0xAB, count: 20))
    }

    @Test("starts over when a first piece arrives in the middle of a file")
    func restartsOnFirstPiece() throws {
        let file = try makeActivityFile(try activityID(FileFlags.sleep, version: 5), content: Data(repeating: 1, count: 20))
        var assembler = ActivityFileAssembler()
        let parts = pieces(of: file, size: 12)

        _ = assembler.append(parts[0])
        let outcomes = parts.map { assembler.append($0) }

        #expect(outcomes.last == .complete(file))
    }

    @Test("rejects a file whose checksum does not match")
    func rejectsCorruptedFile() throws {
        let file = try makeActivityFile(try activityID(FileFlags.sleep, version: 5), content: Data(repeating: 1, count: 20))
        var corrupted = file.raw
        corrupted[10] ^= 0xFF
        var assembler = ActivityFileAssembler()

        let outcome = assembler.append(Data([1, 0, 1, 0]) + corrupted)

        #expect(outcome == .invalid(.unexpectedContent("checksum mismatch")))
    }

    @Test("rejects a piece too short to carry its numbering")
    func rejectsShortPiece() {
        var assembler = ActivityFileAssembler()

        #expect(assembler.append(Data([1, 0])) == .invalid(.truncated))
    }
}

@Suite("Per-minute activity file")
struct DailyDetailsTests {
    /// Groups, one nibble each: steps (present, steps valid), calories (present,
    /// valid), unknown (absent), distance, heart rate (present, valid), energy and
    /// another unknown (absent), SpO₂ and stress (present, valid).
    private let header = Data(hex: "9a0cc00cc0")

    @Test("reads steps, calories, distance, heart rate, SpO₂ and stress of each minute")
    func parsesMinutes() throws {
        let id = try activityID(FileFlags.dailyDetails, version: 3)
        let file = try makeActivityFile(id, content: header + Data(hex: "7800" + "05" + "5a00" + "48" + "61" + "1e"))

        let minutes = try DailyDetails.parse(file)

        #expect(minutes == [
            ActivityMinute(
                start: id.date, steps: 120, activeCalories: 5, distanceMeters: 90,
                heartRate: 72, oxygenSaturation: 97, stress: 30
            ),
        ])
    }

    @Test("gives each record the next minute and drops values the band did not measure")
    func dropsUnmeasuredValues() throws {
        let id = try activityID(FileFlags.dailyDetails, version: 3)
        let idle = Data(hex: "0000" + "00" + "0000" + "00" + "00" + "ff")
        let file = try makeActivityFile(id, content: header + Data(hex: "7800055a0048611e") + idle)

        let minutes = try DailyDetails.parse(file)

        #expect(minutes.count == 2)
        #expect(minutes.last == ActivityMinute(start: id.date.addingTimeInterval(60)))
    }

    @Test("drops readings outside the plausible range instead of recording them")
    func dropsImplausibleValues() throws {
        let id = try activityID(FileFlags.dailyDetails, version: 3)
        // 16 383 steps in a minute, heart rate 250, SpO₂ 20.
        let file = try makeActivityFile(id, content: header + Data(hex: "ff3f" + "05" + "5a00" + "fa" + "14" + "1e"))

        let minute = try #require(try DailyDetails.parse(file).first)

        #expect(minute.steps == nil)
        #expect(minute.heartRate == nil)
        #expect(minute.oxygenSaturation == nil)
        #expect(minute.activeCalories == 5)
    }

    @Test("skips the extra byte a minute announces in its first group")
    func skipsTrailingByte() throws {
        let id = try activityID(FileFlags.dailyDetails, version: 3)
        // First nibble 0b1011: the "extra byte" flag is valid; bit 14 of the group sets it.
        let flagged = Data(hex: "ba0cc00cc0")
        let record = Data(hex: "7840" + "05" + "5a00" + "48" + "61" + "1e" + "99")
        let file = try makeActivityFile(id, content: flagged + record + record)

        let minutes = try DailyDetails.parse(file)

        #expect(minutes.map(\.steps) == [120, 120])
        #expect(minutes.map(\.heartRate) == [72, 72])
    }

    @Test("reads the two extra groups of version 4 without mixing them into the next minute")
    func parsesVersionFour() throws {
        let id = try activityID(FileFlags.dailyDetails, version: 4)
        // Tenth and eleventh nibbles: light and body momentum groups present.
        let record = Data(hex: "7800" + "05" + "5a00" + "48" + "61" + "1e" + "1111" + "2222")
        let file = try makeActivityFile(id, content: Data(hex: "9a0cc00cc8" + "80") + record + record)

        let minutes = try DailyDetails.parse(file)

        #expect(minutes.map(\.steps) == [120, 120])
    }

    @Test("refuses a file that ends in the middle of a minute instead of cutting it")
    func rejectsTruncatedFile() throws {
        let id = try activityID(FileFlags.dailyDetails, version: 3)
        let file = try makeActivityFile(id, content: header + Data(hex: "7800055a0048611e" + "7800"))

        #expect(throws: ActivityParseError.truncated) {
            try DailyDetails.parse(file)
        }
    }

    @Test("refuses a version whose layout is unknown")
    func rejectsUnknownVersion() throws {
        let file = try makeActivityFile(try activityID(FileFlags.dailyDetails, version: 9), content: Data(count: 12))

        #expect(throws: ActivityParseError.unsupportedVersion(9)) {
            try DailyDetails.parse(file)
        }
    }
}

@Suite("Daily summary file")
struct DailySummaryTests {
    private static let slotWidths = [
        4, 2, 1, 1, 1, 4, 1, 4, 1, 1, 1, 1, 3, 2, 2, 1,
        1, 4, 1, 4, 1, 2, 2, 1, 1, 1, 1, 2, 1, 1, 2, 2,
    ]

    private func content(header: String, values: [Int: Int], slots: Int) -> Data {
        Data(hex: header) + Self.slotWidths.prefix(slots).enumerated().reduce(Data()) { data, slot in
            let value = values[slot.offset] ?? 0
            return data + Data((0..<slot.element).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
        }
    }

    @Test("reads the values the header marks as present and ignores the others")
    func parsesVersionFive() throws {
        let id = try activityID(FileFlags.dailySummary, version: 5)
        // Valid: steps (0), resting heart rate (3), total calories (13). Slot 8 holds a value but is not marked.
        let file = try makeActivityFile(
            id, content: content(header: "90040000", values: [0: 8000, 3: 58, 8: 77, 13: 2100], slots: 32)
        )

        let summary = try DailySummaryFile.parse(file)

        #expect(summary.day == id.date)
        #expect(summary.steps == 8000)
        #expect(summary.restingHeartRate == 58)
        #expect(summary.totalCalories == 2100)
        #expect(summary.averageHeartRate == nil)
    }

    @Test("reads the shorter layout of earlier bands")
    func parsesVersionThree() throws {
        let id = try activityID(FileFlags.dailySummary, version: 3)
        let file = try makeActivityFile(id, content: content(header: "900000", values: [0: 1234, 3: 61], slots: 21))

        let summary = try DailySummaryFile.parse(file)

        #expect(summary.steps == 1234)
        #expect(summary.restingHeartRate == 61)
    }

    @Test("drops a resting heart rate outside the plausible range")
    func dropsImplausibleHeartRate() throws {
        let id = try activityID(FileFlags.dailySummary, version: 5)
        let file = try makeActivityFile(id, content: content(header: "10000000", values: [3: 255], slots: 32))

        #expect(try DailySummaryFile.parse(file).restingHeartRate == nil)
    }

    @Test("reads a real Band 10 file, which stops before the last two reserved slots")
    func parsesRealBandFile() throws {
        // Captured from a Band 10 on 2026-10-14: an empty day, 69 bytes in all.
        let raw = Data(hex: "00c6ce6a00050100") + Data(count: 57) + Data(hex: "dae4e401")
        let file = try ActivityFile(raw: raw)

        let summary = try DailySummaryFile.parse(file)

        #expect(summary.steps == nil)
        #expect(summary.restingHeartRate == nil)
    }

    @Test("reads the values that fit and leaves the rest absent when the file is short")
    func readsShortFile() throws {
        let file = try makeActivityFile(
            try activityID(FileFlags.dailySummary, version: 5), content: Data(hex: "80000000" + "401f0000" + "00")
        )

        let summary = try DailySummaryFile.parse(file)

        #expect(summary.steps == 8000)
        #expect(summary.totalCalories == nil)
    }
}

@Suite("Sleep files")
struct SleepTests {
    private let bedTime: UInt32 = 1_700_000_000

    private func littleEndian(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(8 * $0)) })
    }

    private func packet(type: UInt8, timestamp: UInt32, lengthField: UInt16, data: Data = Data()) -> Data {
        Data(hex: "fbfafcff" + "11") + littleEndian(timestamp) + Data(count: 4) + Data([0x01, type])
            + Data([UInt8(lengthField >> 8), UInt8(lengthField & 0xFF)]) + data
    }

    /// Version 5: sleep quality and a heart-rate series are present, then packets.
    /// The flag byte is 1 once the band closed the sleep.
    private func detailsContent(wokeUp: UInt8 = 1, packets: Data) -> Data {
        let preamble = Data(hex: "1040") + Data([wokeUp]) + littleEndian(bedTime) + littleEndian(bedTime + 2700)
        let quality = Data([80])
        let extended = Data(count: 9) + littleEndian(bedTime - 1800) + littleEndian(bedTime + 2700)
        let heartRates = Data(hex: "3c00" + "0200") + littleEndian(bedTime) + Data([55, 56])
        return preamble + quality + extended + heartRates + packets
    }

    @Test("reads bed time, wake time and the stages with their durations")
    func parsesDetails() throws {
        let stages = packet(type: 17, timestamp: bedTime, lengthField: 4, data: Data(hex: "101e" + "200f"))
        // A packet type without data: its length field holds flags and must not be skipped as data.
        let marker = packet(type: 2, timestamp: bedTime, lengthField: 5)
        let file = try makeActivityFile(
            try activityID(FileFlags.sleep, version: 5), content: detailsContent(packets: marker + stages)
        )

        let session = try SleepDetails.parse(file)

        let start = Date(timeIntervalSince1970: TimeInterval(bedTime))
        #expect(session.bedTime == start)
        #expect(session.wakeTime == start.addingTimeInterval(2700))
        #expect(session.isFinished)
        #expect(session.segments == [
            SleepSegment(stage: .light, start: start, end: start.addingTimeInterval(1800)),
            SleepSegment(stage: .deep, start: start.addingTimeInterval(1800), end: start.addingTimeInterval(2700)),
        ])
    }

    @Test("keeps only the band's last scoring of the night")
    func keepsLastScoring() throws {
        // The band re-scores the night from bed time: light 30 then (later) light 20 + deep 25.
        let early = packet(type: 17, timestamp: bedTime, lengthField: 2, data: Data(hex: "101e"))
        let late = packet(type: 17, timestamp: bedTime, lengthField: 4, data: Data(hex: "1014" + "2019"))
        let empty = packet(type: 17, timestamp: bedTime, lengthField: 0)
        let file = try makeActivityFile(
            try activityID(FileFlags.sleep, version: 5), content: detailsContent(packets: early + late + empty)
        )

        let segments = try SleepDetails.parse(file).segments

        let start = Date(timeIntervalSince1970: TimeInterval(bedTime))
        #expect(segments == [
            SleepSegment(stage: .light, start: start, end: start.addingTimeInterval(1200)),
            SleepSegment(stage: .deep, start: start.addingTimeInterval(1200), end: start.addingTimeInterval(2700)),
        ])
    }

    @Test("advances past a stage it cannot name without recording it")
    func skipsUnknownStage() throws {
        // Light 10 min, "not asleep" (4) 5 min, REM 10 min.
        let stages = packet(type: 17, timestamp: bedTime, lengthField: 6, data: Data(hex: "100a" + "4005" + "300a"))
        let file = try makeActivityFile(try activityID(FileFlags.sleep, version: 5), content: detailsContent(packets: stages))

        let segments = try SleepDetails.parse(file).segments

        let start = Date(timeIntervalSince1970: TimeInterval(bedTime))
        #expect(segments.map(\.stage) == [.light, .rem])
        #expect(segments.last?.start == start.addingTimeInterval(900))
    }

    @Test("marks a night the band has not closed yet")
    func flagsUnfinishedNight() throws {
        let file = try makeActivityFile(
            try activityID(FileFlags.sleep, version: 5), content: detailsContent(wokeUp: 0, packets: Data())
        )

        let session = try SleepDetails.parse(file)

        #expect(!session.isFinished)
        #expect(session.segments.isEmpty)
    }

    @Test("keeps the stages read before a packet that is cut short")
    func keepsStagesBeforeTruncatedPacket() throws {
        let stages = packet(type: 17, timestamp: bedTime, lengthField: 2, data: Data(hex: "101e"))
        let cut = packet(type: 1, timestamp: bedTime, lengthField: 40, data: Data(count: 3))
        let file = try makeActivityFile(
            try activityID(FileFlags.sleep, version: 5), content: detailsContent(packets: stages + cut)
        )

        #expect(try SleepDetails.parse(file).segments.count == 1)
    }

    private func packet(type: UInt8, milliseconds: UInt64, lengthField: UInt16) -> Data {
        let stamp = Data((0..<8).map { UInt8(truncatingIfNeeded: milliseconds >> UInt64(8 * $0)) })
        return Data(hex: "fbfafcff" + "11") + stamp + Data([0x00, type])
            + Data([UInt8(lengthField >> 8), UInt8(lengthField & 0xFF)])
    }

    @Test("builds the sleep from fell-asleep and woke-up events when the band sent no stages")
    func parsesSleepWithoutStages() throws {
        // Layout of a real Band 10 nap: events in milliseconds, empty stage packets,
        // and data-less packet types (18) whose length field holds flags.
        let ms = UInt64(bedTime) * 1000
        let packets = [
            packet(type: 18, milliseconds: ms, lengthField: 2),
            packet(type: 2, milliseconds: ms, lengthField: 0),
            packet(type: 3, milliseconds: ms + 1_800_000, lengthField: 5),
            packet(type: 17, timestamp: bedTime, lengthField: 0),
            packet(type: 2, milliseconds: ms + 3_420_000, lengthField: 0),
            packet(type: 3, milliseconds: ms + 5_400_000, lengthField: 5),
            // The band repeats earlier events in later blocks.
            packet(type: 2, milliseconds: ms, lengthField: 0),
            packet(type: 3, milliseconds: ms + 1_800_000, lengthField: 5),
        ].reduce(Data(), +)
        let file = try makeActivityFile(try activityID(FileFlags.sleep, version: 5), content: detailsContent(packets: packets))

        let session = try SleepDetails.parse(file)

        let start = Date(timeIntervalSince1970: TimeInterval(bedTime))
        #expect(session.isFinished)
        #expect(session.segments == [
            SleepSegment(stage: .unspecified, start: start, end: start.addingTimeInterval(1800)),
            SleepSegment(stage: .awake, start: start.addingTimeInterval(1800), end: start.addingTimeInterval(3420)),
            SleepSegment(stage: .unspecified, start: start.addingTimeInterval(3420), end: start.addingTimeInterval(5400)),
        ])
    }

    @Test("keeps two sleeps far apart separate instead of filling the day with awake time")
    func separatesDistantSleeps() throws {
        let ms = UInt64(bedTime) * 1000
        let packets = [
            packet(type: 2, milliseconds: ms, lengthField: 0),
            packet(type: 3, milliseconds: ms + 1_800_000, lengthField: 5),
            packet(type: 2, milliseconds: ms + 6 * 3_600_000, lengthField: 0),
            packet(type: 3, milliseconds: ms + 7 * 3_600_000, lengthField: 5),
        ].reduce(Data(), +)
        let file = try makeActivityFile(try activityID(FileFlags.sleep, version: 5), content: detailsContent(packets: packets))

        #expect(try SleepDetails.parse(file).segments.map(\.stage) == [.unspecified, .unspecified])
    }

    @Test("reads the one-byte header of earlier versions")
    func parsesVersionTwo() throws {
        // No optional field present.
        let content = Data(hex: "00" + "00") + littleEndian(bedTime) + littleEndian(bedTime + 600)
            + packet(type: 17, timestamp: bedTime, lengthField: 2, data: Data(hex: "200a"))
        let file = try makeActivityFile(try activityID(FileFlags.sleep, version: 2), content: content)

        #expect(try SleepDetails.parse(file).segments.map(\.stage) == [.deep])
    }

    @Test("turns stage changes into segments that end at the next change or at wake-up")
    func parsesStageChanges() throws {
        let totals: [Data] = [
            Data(count: 7), Data(hex: "1900"), littleEndian(bedTime), littleEndian(bedTime + 1500), Data(count: 12),
        ]
        let changes: [Data] = [
            littleEndian(bedTime), Data([3]),
            littleEndian(bedTime + 600), Data([2]),
            littleEndian(bedTime + 1200), Data([5]),
        ]
        let content = (totals + changes).reduce(Data(), +)
        let file = try makeActivityFile(try activityID(FileFlags.sleepStages, version: 2), content: content)

        let session = try #require(try SleepStagesFile.parse(file))

        let start = Date(timeIntervalSince1970: TimeInterval(bedTime))
        #expect(session.segments == [
            SleepSegment(stage: .light, start: start, end: start.addingTimeInterval(600)),
            SleepSegment(stage: .deep, start: start.addingTimeInterval(600), end: start.addingTimeInterval(1200)),
            SleepSegment(stage: .awake, start: start.addingTimeInterval(1200), end: start.addingTimeInterval(1500)),
        ])
    }

    @Test("reads a stage-change file without sleep as nothing to record")
    func ignoresEmptyStageFile() throws {
        let file = try makeActivityFile(try activityID(FileFlags.sleepStages, version: 2), content: Data(count: 29))

        #expect(try SleepStagesFile.parse(file) == nil)
        #expect(try ActivityContent.decode(file) == .empty)
    }
}

@Suite("Spot measurement file")
struct ManualSamplesTests {
    private func entry(_ offset: UInt32, _ type: UInt8, _ value: [UInt8]) -> Data {
        let time: UInt32 = 1_700_000_000 + offset
        let stamp: [UInt8] = (0..<4).map { UInt8(truncatingIfNeeded: time >> UInt32(8 * $0)) }
        return Data(stamp) + Data([type]) + Data(value)
    }

    @Test("reads heart rate, SpO₂ and stress, skipping temperature and empty readings")
    func parsesCurrentVersion() throws {
        let entries: [Data] = [
            entry(0, 0x12, [97]), entry(60, 0x13, [0]), entry(120, 0x44, [0x5A, 0x0E, 0, 0]),
            entry(180, 0x11, [64]), entry(240, 0x13, [28]),
        ]
        let content = entries.reduce(Data(), +)
        let file = try makeActivityFile(try activityID(FileFlags.manualSamples, version: 2), content: content)

        let samples = try ManualSamplesFile.parse(file)

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(samples == [
            ManualSample(kind: .oxygenSaturation, date: start, value: 97),
            ManualSample(kind: .heartRate, date: start.addingTimeInterval(180), value: 64),
            ManualSample(kind: .stress, date: start.addingTimeInterval(240), value: 28),
        ])
    }

    @Test("stops at a sample type of unknown width instead of guessing")
    func rejectsUnknownType() throws {
        let file = try makeActivityFile(
            try activityID(FileFlags.manualSamples, version: 2), content: entry(0, 0x77, [1])
        )

        #expect(throws: ActivityParseError.unexpectedContent("manual sample type 119")) {
            try ManualSamplesFile.parse(file)
        }
    }

    @Test("reads the older layout with its header byte and its own type codes")
    func parsesLegacyVersion() throws {
        let content: Data = [Data([0xFF]), entry(0, 0x02, [96]), entry(60, 0x03, [40])].reduce(Data(), +)
        let file = try makeActivityFile(try activityID(FileFlags.manualSamples, version: 1), content: content)

        #expect(try ManualSamplesFile.parse(file).map(\.kind) == [.oxygenSaturation, .stress])
    }
}

@Suite("Activity content")
struct ActivityContentTests {
    @Test("decodes a file according to the kind its identifier announces")
    func decodesByKind() throws {
        let file = try makeActivityFile(
            try activityID(FileFlags.manualSamples, version: 2), content: Data(hex: "00f15365" + "11" + "40")
        )

        guard case .manualSamples(let samples) = try ActivityContent.decode(file) else {
            Issue.record("expected manual samples")
            return
        }
        #expect(samples.map(\.value) == [64])
    }

    @Test("refuses workout files, which are left on the band")
    func rejectsWorkouts() throws {
        let file = try makeActivityFile(try activityID(FileFlags.workoutSummary, version: 1), content: Data(count: 4))

        #expect(!ActivityContent.isSupported(file.id.kind))
        #expect(throws: ActivityParseError.self) {
            try ActivityContent.decode(file)
        }
    }
}
