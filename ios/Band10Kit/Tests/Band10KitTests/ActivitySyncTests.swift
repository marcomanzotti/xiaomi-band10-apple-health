import Foundation
import Testing
@testable import Band10Kit

// Command layout follows Gadgetbridge's XiaomiHealthService and wear_fitness.proto.

@Suite("Health commands")
struct HealthCommandTests {
    private let fileID = Data(hex: "8a90a965080520")

    @Test("asks for today's files with the zero the official app sends")
    func buildsListToday() {
        #expect(HealthCommand.listToday == Data(hex: "0808" + "1001" + "5204" + "2a02" + "0800"))
    }

    @Test("asks for the files of earlier days with a bare command")
    func buildsListPastDays() {
        #expect(HealthCommand.listPastDays == Data(hex: "0808" + "1002"))
    }

    @Test("requests and acknowledges a file by its identifier")
    func buildsRequestAndAcknowledgement() throws {
        let id = try ActivityFileID(decoding: fileID)

        #expect(HealthCommand.request(id) == Data(hex: "0808" + "1003" + "5209" + "1207") + fileID)
        #expect(HealthCommand.acknowledge(id) == Data(hex: "0808" + "1005" + "5209" + "1a07") + fileID)
    }

    @Test("reads the list of files the band holds", arguments: [
        (1, .today),
        (2, .pastDays),
    ] as [(UInt8, HealthReply.Scope)])
    func parsesFileList(subtype: UInt8, scope: HealthReply.Scope) throws {
        let reply = Data([0x08, 0x08, 0x10, subtype]) + Data(hex: "5209" + "1207") + fileID

        #expect(try HealthReply.parse(reply) == .files(scope, [try ActivityFileID(decoding: fileID)]))
    }

    @Test("reads a reply without files as an empty list")
    func parsesEmptyFileList() throws {
        #expect(try HealthReply.parse(Data(hex: "08081002")) == .files(.pastDays, []))
    }

    @Test("passes over health commands that are not file lists")
    func parsesOtherSubtype() throws {
        #expect(try HealthReply.parse(Data(hex: "0808102f")) == .other(subtype: 47))
    }

    @Test("refuses a command of another type")
    func rejectsOtherType() {
        #expect(throws: HealthReplyError.unexpectedCommandType(2)) {
            try HealthReply.parse(Data(hex: "08021001"))
        }
    }

    @Test("reports a file list that is not a whole number of identifiers")
    func rejectsMalformedList() {
        #expect(throws: HealthReplyError.self) {
            try HealthReply.parse(Data(hex: "0808" + "1001" + "5204" + "1202" + "0102"))
        }
    }

    @Test("reads the type and subtype of any command")
    func parsesHeader() throws {
        #expect(try CommandHeader.parse(Data(hex: "080a1003")) == CommandHeader(type: 10, subtype: 3))
    }
}

@Suite("Clock command")
struct ClockCommandTests {
    private func date(_ zone: TimeZone, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return try #require(calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )))
    }

    @Test("sends local date and time with the zone split into standard and daylight offsets")
    func buildsSummerClock() throws {
        let rome = try #require(TimeZone(identifier: "Europe/Rome"))
        let day = "0a07" + "08ea0f" + "100a" + "180e"
        let time = "1208" + "080c" + "1022" + "1838" + "2000"
        // One hour of standard offset and one of daylight saving, in quarters, zig-zag encoded.
        let zone = "1a11" + "0808" + "1008" + "1a0b"
        let expected = Data(hex: "0802" + "1003" + "222a" + "2228" + day + time + zone)
            + Data("Europe/Rome".utf8) + Data(hex: "2000")

        #expect(SystemCommand.setClock(to: try date(rome, 2026, 10, 14, 12, 34, 56), in: rome) == expected)
    }

    @Test("encodes a zone west of Greenwich as a negative offset")
    func buildsNegativeOffset() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))

        let command = SystemCommand.setClock(to: try date(newYork, 2026, 1, 15, 8, 0, 0), in: newYork, usesTwelveHourFormat: true)

        // -20 quarters of an hour is 39 in zig-zag; no daylight saving in January.
        #expect(command.range(of: Data(hex: "0827" + "1000" + "1a10") + Data("America/New_York".utf8)) != nil)
        #expect(command.suffix(2) == Data(hex: "2001"))
    }
}

@Suite("Activity download sequence")
struct ActivitySyncTests {
    private func pieces(of file: ActivityFile) -> [Data] {
        let half = file.raw.count / 2
        return [
            Data([2, 0, 1, 0]) + file.raw.prefix(half),
            Data([2, 0, 2, 0]) + file.raw.suffix(file.raw.count - half),
        ]
    }

    /// A readable file: one spot heart-rate measurement.
    private func readableFile(timestamp: UInt32) throws -> ActivityFile {
        try makeActivityFile(
            try activityID(FileFlags.manualSamples, version: 2, timestamp: timestamp), content: Data(hex: "00f15365" + "11" + "40")
        )
    }

    private func started(_ sync: inout ActivitySync, today: [ActivityFileID], past: [ActivityFileID] = []) {
        _ = sync.start()
        _ = sync.handle(.files(.today, today))
        _ = sync.handle(.files(.pastDays, past))
    }

    @Test("lists today's files, then earlier ones, then fetches oldest first and acknowledges each")
    func runsFullSequence() throws {
        let today = try readableFile(timestamp: 2000)
        let earlier = try readableFile(timestamp: 1000)
        var sync = ActivitySync()

        #expect(sync.start() == [.send(HealthCommand.listToday)])
        #expect(sync.handle(.files(.today, [today.id])) == [.send(HealthCommand.listPastDays)])
        #expect(sync.handle(.files(.pastDays, [earlier.id])) == [.send(HealthCommand.request(earlier.id))])

        #expect(sync.handle(piece: pieces(of: earlier)[0]) == [])
        #expect(sync.handle(piece: pieces(of: earlier)[1]) == [
            .store(earlier),
            .send(HealthCommand.acknowledge(earlier.id)),
            .send(HealthCommand.request(today.id)),
        ])
        let last = pieces(of: today).flatMap { sync.handle(piece: $0) }
        #expect(last == [
            .store(today),
            .send(HealthCommand.acknowledge(today.id)),
            .finished(ActivitySync.Summary(received: 2)),
        ])
        #expect(!sync.isWaitingForBand)
    }

    @Test("keeps a file it cannot read on the band, so that a later version of the app can read it")
    func doesNotAcknowledgeUnreadableFile() throws {
        // Daily details of a layout version this library does not know.
        let unknown = try makeActivityFile(try activityID(FileFlags.dailyDetails, version: 9), content: Data(count: 12))
        var sync = ActivitySync()
        started(&sync, today: [unknown.id])

        let actions = pieces(of: unknown).flatMap { sync.handle(piece: $0) }

        #expect(actions == [.store(unknown), .finished(ActivitySync.Summary(received: 1, kept: 1))])
    }

    @Test("keeps a night still in progress on the band, so that the complete night comes later")
    func doesNotAcknowledgeUnfinishedNight() throws {
        let night = Data(hex: "00" + "01") + Data(hex: "00f15365") + Data(hex: "10f15365")
        let unfinished = try makeActivityFile(try activityID(FileFlags.sleep, version: 2), content: night)
        var sync = ActivitySync()
        started(&sync, today: [unfinished.id])

        let actions = pieces(of: unfinished).flatMap { sync.handle(piece: $0) }

        #expect(actions.first == .store(unfinished))
        #expect(!actions.contains(.send(HealthCommand.acknowledge(unfinished.id))))
    }

    @Test("leaves the files on the band when told not to acknowledge")
    func skipsAcknowledgement() throws {
        let file = try readableFile(timestamp: 1000)
        var sync = ActivitySync(acknowledgesFiles: false)
        started(&sync, today: [file.id])

        let actions = pieces(of: file).flatMap { sync.handle(piece: $0) }

        #expect(actions == [.store(file), .finished(ActivitySync.Summary(received: 1))])
    }

    @Test("finishes at once when the band has nothing")
    func finishesWithoutFiles() {
        var sync = ActivitySync()
        _ = sync.start()
        _ = sync.handle(.files(.today, []))

        #expect(sync.handle(.files(.pastDays, [])) == [.finished(ActivitySync.Summary())])
    }

    @Test("does not fetch kinds it cannot read and asks for a file listed twice only once")
    func filtersQueue() throws {
        let file = try readableFile(timestamp: 1000)
        let workout = try activityID(FileFlags.workoutSummary, version: 1)
        var sync = ActivitySync(acknowledgesFiles: false)
        started(&sync, today: [file.id, workout], past: [file.id])

        let actions = pieces(of: file).flatMap { sync.handle(piece: $0) }

        #expect(actions.last == .finished(ActivitySync.Summary(received: 1, unsupported: 1)))
    }

    @Test("does not ask again for a file already fetched when a late listing repeats it")
    func ignoresRelistedFetchedFile() throws {
        let first = try readableFile(timestamp: 1000)
        let second = try readableFile(timestamp: 2000)
        var sync = ActivitySync()
        started(&sync, today: [first.id, second.id])
        _ = pieces(of: first).flatMap { sync.handle(piece: $0) }

        #expect(sync.handle(.files(.today, [first.id])) == [])
        let actions = pieces(of: second).flatMap { sync.handle(piece: $0) }

        #expect(actions.last == .finished(ActivitySync.Summary(received: 2)))
    }

    @Test("moves on to the next file when one never arrives or arrives damaged")
    func skipsFailedFiles() throws {
        let lost = try readableFile(timestamp: 1000)
        let damaged = try readableFile(timestamp: 2000)
        let good = try readableFile(timestamp: 3000)
        var sync = ActivitySync()
        started(&sync, today: [lost.id, damaged.id, good.id])

        #expect(sync.handleTimeout() == [.send(HealthCommand.request(damaged.id))])
        var corrupted = damaged.raw
        corrupted[12] ^= 0xFF
        #expect(sync.handle(piece: Data([1, 0, 1, 0]) + corrupted) == [.send(HealthCommand.request(good.id))])
        let actions = pieces(of: good).flatMap { sync.handle(piece: $0) }

        #expect(actions.last == .finished(ActivitySync.Summary(received: 1, failed: 2)))
    }

    @Test("keeps the late answer to a request that timed out without losing the file asked for now")
    func acceptsLateFile() throws {
        let late = try readableFile(timestamp: 1000)
        let next = try readableFile(timestamp: 2000)
        var sync = ActivitySync()
        started(&sync, today: [late.id, next.id])
        _ = sync.handleTimeout()

        #expect(sync.handle(piece: Data([1, 0, 1, 0]) + late.raw) == [
            .store(late), .send(HealthCommand.acknowledge(late.id)),
        ])
        let actions = pieces(of: next).flatMap { sync.handle(piece: $0) }

        #expect(actions.last == .finished(ActivitySync.Summary(received: 2)))
    }

    @Test("ignores a file it did not ask for and keeps waiting for the right one")
    func ignoresUnrequestedFile() throws {
        let asked = try readableFile(timestamp: 1000)
        let other = try readableFile(timestamp: 5000)
        var sync = ActivitySync()
        started(&sync, today: [asked.id])

        #expect(sync.handle(piece: Data([1, 0, 1, 0]) + other.raw) == [])
        #expect(sync.isWaitingForBand)
    }

    @Test("asks for earlier days and reports an incomplete sync when today's listing goes unanswered")
    func survivesSilentListing() throws {
        let file = try readableFile(timestamp: 1000)
        var sync = ActivitySync()
        _ = sync.start()

        #expect(sync.handleTimeout() == [.send(HealthCommand.listPastDays)])
        _ = sync.handle(.files(.pastDays, [file.id]))
        let actions = pieces(of: file).flatMap { sync.handle(piece: $0) }

        #expect(actions.last == .finished(ActivitySync.Summary(received: 1, isComplete: false)))
    }

    @Test("ignores input before it starts and after it finishes")
    func ignoresInputOutsideSequence() throws {
        let file = try readableFile(timestamp: 1000)
        var sync = ActivitySync()

        #expect(sync.handle(.files(.today, [file.id])) == [])
        #expect(sync.handle(piece: Data([1, 0, 1, 0]) + file.raw) == [])
        #expect(sync.handleTimeout() == [])
        _ = sync.start()
        #expect(sync.start() == [])
    }
}

@Suite("Health samples")
struct HealthSamplesTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("turns a minute into steps, energy and distance over the minute plus instant heart rate and SpO₂")
    func mapsMinute() {
        let minute = ActivityMinute(
            start: start, steps: 120, activeCalories: 5, distanceMeters: 90, heartRate: 72, oxygenSaturation: 97, stress: 30
        )

        let samples = HealthSamples.make(from: .minutes([minute]), revision: 9)

        let end = start.addingTimeInterval(60)
        #expect(samples == [
            HealthSample(kind: .steps, value: 120, start: start, end: end, syncIdentifier: "band10.steps.1700000000", syncVersion: 120),
            HealthSample(kind: .activeEnergy, value: 5, start: start, end: end, syncIdentifier: "band10.energy.1700000000", syncVersion: 5),
            HealthSample(kind: .distance, value: 90, start: start, end: end, syncIdentifier: "band10.distance.1700000000", syncVersion: 90),
            HealthSample(kind: .heartRate, value: 72, start: start, end: start, syncIdentifier: "band10.hr.1700000000", syncVersion: 1),
            HealthSample(kind: .oxygenSaturation, value: 0.97, start: start, end: start, syncIdentifier: "band10.spo2.1700000000", syncVersion: 1),
        ])
    }

    @Test("produces nothing for a minute without measurements")
    func skipsEmptyMinute() {
        #expect(HealthSamples.make(from: .minutes([ActivityMinute(start: start)]), revision: 1).isEmpty)
    }

    @Test("writes the day's resting heart rate with the revision of the sync, so that a later value replaces it")
    func mapsSummary() {
        let summary = DailySummary(
            day: start, steps: 8000, activeCalories: 300, totalCalories: 2100, restingHeartRate: 58,
            maximumHeartRate: nil, minimumHeartRate: nil, averageHeartRate: nil,
            averageOxygenSaturation: nil, averageStress: nil
        )

        #expect(HealthSamples.make(from: .summary(summary), revision: 42) == [
            HealthSample(
                kind: .restingHeartRate, value: 58, start: start, end: start,
                syncIdentifier: "band10.resting-hr.1700000000", syncVersion: 42
            ),
        ])
    }

    @Test("writes one sample per sleep stage of a finished night")
    func mapsSleep() {
        let middle = start.addingTimeInterval(1800)
        let end = start.addingTimeInterval(2700)
        let session = SleepSession(bedTime: start, wakeTime: end, isFinished: true, segments: [
            SleepSegment(stage: .light, start: start, end: middle),
            SleepSegment(stage: .deep, start: middle, end: end),
        ])

        let samples = HealthSamples.make(from: .sleep(session), revision: 1)

        #expect(samples.map(\.kind) == [.sleep(.light), .sleep(.deep)])
        #expect(samples.map(\.syncIdentifier) == ["band10.sleep.1700000000", "band10.sleep.1700001800"])
        #expect(samples.map(\.syncVersion) == [1_700_001_800, 1_700_002_700])
    }

    @Test("writes a night still in progress too, keyed so that the complete night extends it")
    func writesUnfinishedSleep() {
        let session = SleepSession(bedTime: start, wakeTime: start, isFinished: false, segments: [
            SleepSegment(stage: .light, start: start, end: start.addingTimeInterval(600)),
        ])

        let samples = HealthSamples.make(from: .sleep(session), revision: 1)

        #expect(samples.map(\.syncIdentifier) == ["band10.sleep.1700000000"])
        #expect(samples.map(\.syncVersion) == [1_700_000_600])
    }

    @Test("writes spot heart rate and SpO₂, and leaves out stress, which Health cannot hold")
    func mapsManualSamples() {
        let manual = [
            ManualSample(kind: .heartRate, date: start, value: 64),
            ManualSample(kind: .oxygenSaturation, date: start, value: 98),
            ManualSample(kind: .stress, date: start, value: 30),
        ]

        let samples = HealthSamples.make(from: .manualSamples(manual), revision: 1)

        #expect(samples.map(\.kind) == [.heartRate, .oxygenSaturation])
        #expect(samples.map(\.value) == [64, 0.98])
        #expect(samples.map(\.syncIdentifier) == ["band10.manual-hr.1700000000", "band10.manual-spo2.1700000000"])
    }

    @Test("produces nothing for an empty file")
    func mapsEmpty() {
        #expect(HealthSamples.make(from: .empty, revision: 1).isEmpty)
    }
}
