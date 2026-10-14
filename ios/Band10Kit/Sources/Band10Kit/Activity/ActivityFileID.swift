// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Layout derived from Gadgetbridge (XiaomiActivityFileId), AGPL-3.0.

import Foundation

/// The 7-byte name of a file of recorded data on the band:
/// `timestamp (4, little endian) | timezone | version | flags`.
public struct ActivityFileID: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// One entry per minute: steps, calories, distance, heart rate, SpO₂, stress.
        case dailyDetails
        case dailySummary
        case sleepStages
        /// Spot measurements started by hand on the band.
        case manualSamples
        /// A night's sleep with its stages.
        case sleep
        case workout
        case unknown
    }

    public static let encodedLength = 7

    private enum Category {
        static let activity = 0
        static let sports = 1
    }

    private enum ActivitySubtype {
        static let daily = 0x00
        static let sleepStages = 0x03
        static let manualSamples = 0x06
        static let sleep = 0x08
    }

    private enum Detail {
        static let details = 0
        static let summary = 1
        static let gpsTrack = 2
    }

    private static let categoryShift = 7
    private static let subtypeShift = 2
    private static let subtypeMask = 0x1F
    private static let detailMask = 0x03

    /// Start of the recording, in seconds since 1970.
    public let timestamp: UInt32
    /// Offset from UTC in quarters of an hour.
    public let timezone: Int8
    /// Format revision of the file content.
    public let version: Int
    /// 0 for everyday activity, 1 for workouts.
    public let category: Int
    public let subtype: Int
    public let detail: Int

    public init(timestamp: UInt32, timezone: Int8, version: Int, category: Int, subtype: Int, detail: Int) {
        self.timestamp = timestamp
        self.timezone = timezone
        self.version = version
        self.category = category
        self.subtype = subtype
        self.detail = detail
    }

    /// Reads an identifier from the first seven bytes of `data`.
    public init(decoding data: Data) throws(ActivityParseError) {
        var reader = ByteReader(data)
        let timestamp = try reader.uint32()
        let timezone = Int8(bitPattern: try reader.byte())
        let version = Int(try reader.byte())
        let flags = Int(try reader.byte())
        self.init(
            timestamp: timestamp,
            timezone: timezone,
            version: version,
            category: flags >> Self.categoryShift & 1,
            subtype: flags >> Self.subtypeShift & Self.subtypeMask,
            detail: flags & Self.detailMask
        )
    }

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    public var kind: Kind {
        guard category == Category.activity else {
            return category == Category.sports ? .workout : .unknown
        }
        switch (subtype, detail) {
        case (ActivitySubtype.daily, Detail.details): return .dailyDetails
        case (ActivitySubtype.daily, Detail.summary): return .dailySummary
        case (ActivitySubtype.sleepStages, Detail.details): return .sleepStages
        case (ActivitySubtype.manualSamples, Detail.details): return .manualSamples
        case (ActivitySubtype.sleep, _): return .sleep
        default: return .unknown
        }
    }

    public func encoded() -> Data {
        let flags = category << Self.categoryShift | subtype << Self.subtypeShift | detail
        let stamp = (0..<4).map { UInt8(truncatingIfNeeded: timestamp >> UInt32(8 * $0)) }
        return Data(stamp + [UInt8(bitPattern: timezone), UInt8(truncatingIfNeeded: version), UInt8(truncatingIfNeeded: flags)])
    }

    /// Splits the concatenated identifiers the band sends when asked what it has.
    public static func list(decoding data: Data) throws(ActivityParseError) -> [ActivityFileID] {
        guard data.count.isMultiple(of: encodedLength) else {
            throw .unexpectedContent("identifier list of \(data.count) bytes")
        }
        var identifiers: [ActivityFileID] = []
        for start in stride(from: 0, to: data.count, by: encodedLength) {
            let identifier = try ActivityFileID(decoding: data.subdata(in: data.startIndex + start..<data.startIndex + start + encodedLength))
            // An all-zero entry is padding, not a file.
            if identifier.timestamp != 0 || identifier.version != 0 {
                identifiers.append(identifier)
            }
        }
        return identifiers
    }
}

extension ActivityFileID: CustomStringConvertible {
    public var description: String {
        "\(kind) t=\(timestamp) tz=\(timezone) v\(version) [\(category).\(subtype).\(detail)]"
    }

    /// A stable name for storing the file on disk.
    public var filename: String {
        encoded().map { String(format: "%02x", $0) }.joined() + ".bin"
    }
}
