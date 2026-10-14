// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Layout derived from Gadgetbridge (SleepDetailsParser, SleepStagesParser), AGPL-3.0.

import Foundation

public enum SleepStage: Equatable, Sendable {
    case awake
    case light
    case deep
    case rem
}

public struct SleepSegment: Equatable, Sendable {
    public let stage: SleepStage
    public let start: Date
    public let end: Date

    public init(stage: SleepStage, start: Date, end: Date) {
        self.stage = stage
        self.start = start
        self.end = end
    }
}

/// One period of sleep as the band scored it.
public struct SleepSession: Equatable, Sendable {
    public let bedTime: Date
    public let wakeTime: Date
    /// False while the band still considers the wearer asleep: the session will
    /// be sent again, longer, once it ends.
    public let isFinished: Bool
    /// Consecutive stages, in order; empty when the band sent no staging.
    public let segments: [SleepSegment]

    public init(bedTime: Date, wakeTime: Date, isFinished: Bool, segments: [SleepSegment]) {
        self.bedTime = bedTime
        self.wakeTime = wakeTime
        self.isFinished = isFinished
        self.segments = segments
    }
}

/// Reads the detailed sleep file: a fixed preamble, optional sample series, then
/// a sequence of marked packets of which one kind holds the stages.
public enum SleepDetails {
    private static let qualityVersion = 4
    private static let extendedPreambleVersion = 5
    private static let firstRecordTimeVersion = 2
    private static let snoreVersion = 3
    private static let extendedPreambleLength = 9 + 4 + 4
    private static let extendedPreambleFields = 5
    private static let snoreSampleWidth = 4
    /// The fields before the optional ones: the still-asleep flag, bed time and wake time.
    private static let fixedFields = 3

    /// Bytes `FB FA FC FF` open every packet.
    private static let packetMarker: UInt32 = 0xFFFC_FAFB
    /// Marker, header length, timestamp, parity, type and data length.
    private static let packetHeaderLength = 4 + 1 + 8 + 1 + 1 + 2
    private static let stagesPacket: UInt8 = 17
    /// Packet types whose length field holds flags: no data follows them.
    private static let packetsWithoutData: Set<UInt8> = [2, 3, 9, 12, 13, 14, 15]
    private static let stageShift: UInt16 = 12
    private static let durationMask: UInt16 = 0x0FFF
    private static let secondsPerMinute: TimeInterval = 60

    public static func parse(_ file: ActivityFile) throws(ActivityParseError) -> SleepSession {
        let version = file.id.version
        var reader = ByteReader(file.content)
        let validity = ValidityBitmap(header: try reader.take(try headerLength(version: version)))

        let stillAsleep = try reader.byte() == 1
        let bedTime = try reader.uint32()
        let wakeTime = try reader.uint32()
        var field = fixedFields
        if version >= qualityVersion {
            if validity.isValid(field) {
                try reader.skip(1)
            }
            field += 1
        }
        if version >= extendedPreambleVersion {
            try reader.skip(extendedPreambleLength)
            field += extendedPreambleFields
        }
        // Heart rate and SpO₂ during the night: the per-minute file already has them.
        for _ in 0..<2 {
            if validity.isValid(field) {
                try skipSeries(sampleWidth: 1, version: version, from: &reader)
            }
            field += 1
        }
        if version >= snoreVersion, validity.isValid(field) {
            try skipSeries(sampleWidth: snoreSampleWidth, version: version, from: &reader)
        }

        return SleepSession(
            bedTime: Date(timeIntervalSince1970: TimeInterval(bedTime)),
            wakeTime: Date(timeIntervalSince1970: TimeInterval(wakeTime)),
            isFinished: !stillAsleep,
            segments: readSegments(from: &reader)
        )
    }

    private static func headerLength(version: Int) throws(ActivityParseError) -> Int {
        switch version {
        case 1...4: 1
        case 5: 2
        default: throw .unsupportedVersion(version)
        }
    }

    /// A series is `interval (2) | count (2) | first sample time (4, if any) | samples`.
    private static func skipSeries(
        sampleWidth: Int, version: Int, from reader: inout ByteReader
    ) throws(ActivityParseError) {
        try reader.skip(2)
        let count = Int(try reader.uint16())
        guard count > 0 else { return }
        if version >= firstRecordTimeVersion {
            try reader.skip(4)
        }
        try reader.skip(count * sampleWidth)
    }

    /// The packet area is not fully understood, so a malformed tail ends the
    /// reading and keeps the stages found so far.
    private static func readSegments(from reader: inout ByteReader) -> [SleepSegment] {
        var segments: [SleepSegment] = []
        while let packet = try? nextPacket(from: &reader) {
            guard packet.type == stagesPacket else { continue }
            segments.append(contentsOf: decodeStages(packet.data, startingAt: packet.timestamp))
        }
        return segments
    }

    private static func nextPacket(
        from reader: inout ByteReader
    ) throws(ActivityParseError) -> (type: UInt8, timestamp: UInt64, data: Data)? {
        guard try seekMarker(in: &reader) else { return nil }
        try reader.skip(1)
        let timestamp = try reader.uint64()
        try reader.skip(1)
        let type = try reader.byte()
        let length = Int(try reader.bigEndianUInt16())
        if packetsWithoutData.contains(type) {
            return (type, timestamp, Data())
        }
        return (type, timestamp, Data(try reader.take(length)))
    }

    private static func seekMarker(in reader: inout ByteReader) throws(ActivityParseError) -> Bool {
        while reader.remaining >= packetHeaderLength {
            if try reader.uint32() == packetMarker {
                return true
            }
            reader.rewind(3)
        }
        return false
    }

    /// Each entry is a big-endian pair `stage (4 bits) | minutes (12 bits)`.
    private static func decodeStages(_ data: Data, startingAt timestamp: UInt64) -> [SleepSegment] {
        var reader = ByteReader(data)
        var segments: [SleepSegment] = []
        var start = Date(timeIntervalSince1970: TimeInterval(timestamp))
        while let entry = try? reader.bigEndianUInt16() {
            let end = start.addingTimeInterval(TimeInterval(entry & durationMask) * secondsPerMinute)
            if let stage = stage(code: entry >> stageShift), end > start {
                segments.append(SleepSegment(stage: stage, start: start, end: end))
            }
            start = end
        }
        return segments
    }

    private static func stage(code: UInt16) -> SleepStage? {
        switch code {
        case 0: .awake
        case 1: .light
        case 2: .deep
        case 3: .rem
        default: nil
        }
    }
}

/// Reads the older sleep file: totals, then the moments at which the stage changed.
public enum SleepStagesFile {
    private static let supportedVersion = 2
    private static let leadingUnknownLength = 7
    private static let middleUnknownLength = 3
    /// Deep, light, REM and awake totals, then one unknown byte.
    private static let totalsLength = 4 * 2 + 1
    private static let changeLength = 4 + 1

    public static func parse(_ file: ActivityFile) throws(ActivityParseError) -> SleepSession? {
        guard file.id.version == supportedVersion else {
            throw .unsupportedVersion(file.id.version)
        }
        var reader = ByteReader(file.content)
        try reader.skip(leadingUnknownLength)
        let duration = try reader.uint16()
        let bedTime = try reader.uint32()
        let wakeTime = try reader.uint32()
        try reader.skip(middleUnknownLength + totalsLength)
        // The band also sends this file for nights without sleep.
        guard bedTime != 0, wakeTime != 0, duration != 0 else { return nil }

        var changes: [(time: UInt32, code: UInt8)] = []
        while reader.remaining >= changeLength {
            changes.append((try reader.uint32(), try reader.byte()))
        }
        let ends = changes.dropFirst().map(\.time) + [wakeTime]
        let segments = zip(changes, ends).compactMap { change, end -> SleepSegment? in
            guard let stage = stage(code: change.code), end > change.time else { return nil }
            return SleepSegment(
                stage: stage,
                start: Date(timeIntervalSince1970: TimeInterval(change.time)),
                end: Date(timeIntervalSince1970: TimeInterval(end))
            )
        }
        return SleepSession(
            bedTime: Date(timeIntervalSince1970: TimeInterval(bedTime)),
            wakeTime: Date(timeIntervalSince1970: TimeInterval(wakeTime)),
            isFinished: true,
            segments: segments
        )
    }

    private static func stage(code: UInt8) -> SleepStage? {
        switch code {
        case 2: .deep
        case 3: .light
        case 4: .rem
        case 5: .awake
        default: nil
        }
    }
}
