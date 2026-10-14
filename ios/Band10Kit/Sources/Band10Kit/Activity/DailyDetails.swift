// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Layout derived from Gadgetbridge (DailyDetailsParser,
// XiaomiComplexActivityParser), AGPL-3.0.

import Foundation

/// What the band recorded during one minute. A value the band did not measure,
/// or one outside the plausible range, is nil.
public struct ActivityMinute: Equatable, Sendable {
    public let start: Date
    public let steps: Int?
    /// Active energy in kilocalories.
    public let activeCalories: Int?
    public let distanceMeters: Int?
    /// Beats per minute.
    public let heartRate: Int?
    /// Blood oxygen saturation in percent.
    public let oxygenSaturation: Int?
    /// 1…100; the band's own scale.
    public let stress: Int?

    public init(
        start: Date,
        steps: Int? = nil,
        activeCalories: Int? = nil,
        distanceMeters: Int? = nil,
        heartRate: Int? = nil,
        oxygenSaturation: Int? = nil,
        stress: Int? = nil
    ) {
        self.start = start
        self.steps = steps
        self.activeCalories = activeCalories
        self.distanceMeters = distanceMeters
        self.heartRate = heartRate
        self.oxygenSaturation = oxygenSaturation
        self.stress = stress
    }
}

/// Reads the per-minute file. Each minute is a run of value groups; the file
/// header says, one nibble per group, whether the group is present (top bit)
/// and which of its up to three values are meaningful (lower bits).
public enum DailyDetails {
    static let secondsPerMinute: TimeInterval = 60
    private static let oxygenAndStressVersion = 3
    private static let lightAndMomentumVersion = 4
    private static let stressNotMeasured = 255

    /// Bounds outside which a reading is treated as noise and dropped.
    private enum Plausible {
        static let heartRate = 25...240
        static let oxygenSaturation = 60...100
        static let stress = 1...100
        static let stepsPerMinute = 1...400
        static let caloriesPerMinute = 1...63
        static let metersPerMinute = 1...1000
    }

    public static func parse(_ file: ActivityFile) throws(ActivityParseError) -> [ActivityMinute] {
        let version = file.id.version
        var reader = ByteReader(file.content)
        let header = try reader.take(try headerLength(version: version))
        var minutes: [ActivityMinute] = []
        while !reader.isAtEnd {
            let start = file.id.date.addingTimeInterval(TimeInterval(minutes.count) * secondsPerMinute)
            // A file that ends in the middle of a minute was not understood: it
            // stays on the band until the parser is fixed, instead of being cut.
            minutes.append(try readMinute(start: start, version: version, header: header, from: &reader))
        }
        return minutes
    }

    private static func headerLength(version: Int) throws(ActivityParseError) -> Int {
        switch version {
        case 1, 2: 4
        case 3: 5
        case 4: 6
        default: throw .unsupportedVersion(version)
        }
    }

    private static func readMinute(
        start: Date, version: Int, header: [UInt8], from reader: inout ByteReader
    ) throws(ActivityParseError) -> ActivityMinute {
        var groups = ValueGroups(header: header)
        var hasTrailingByte = false
        var steps: Int?
        var calories: Int?
        var distance: Int?
        var heartRate: Int?
        var oxygen: Int?
        var stress: Int?

        if try groups.next(bits: 16, from: &reader) {
            hasTrailingByte = groups.has(1) && groups.value(at: 1, bits: 1) == 1
            steps = groups.has(2) ? groups.value(at: 2, bits: 14) : nil
        }
        if try groups.next(bits: 8, from: &reader) {
            calories = groups.has(1) ? groups.value(at: 2, bits: 6) : nil
        }
        _ = try groups.next(bits: 8, from: &reader)
        if try groups.next(bits: 16, from: &reader) {
            distance = groups.has(0) ? groups.value(at: 0, bits: 16) : nil
        }
        if try groups.next(bits: 8, from: &reader) {
            heartRate = groups.has(0) ? groups.value(at: 0, bits: 8) : nil
        }
        // Body energy, then a group of unknown meaning.
        _ = try groups.next(bits: 8, from: &reader)
        _ = try groups.next(bits: 16, from: &reader)
        if version >= oxygenAndStressVersion {
            if try groups.next(bits: 8, from: &reader) {
                oxygen = groups.has(0) ? groups.value(at: 0, bits: 8) : nil
            }
            if try groups.next(bits: 8, from: &reader) {
                stress = groups.has(0) ? groups.value(at: 0, bits: 8) : nil
            }
        }
        if hasTrailingByte {
            try reader.skip(1)
        }
        if version >= lightAndMomentumVersion {
            // Ambient light and body momentum.
            _ = try groups.next(bits: 16, from: &reader)
            _ = try groups.next(bits: 16, from: &reader)
        }
        return ActivityMinute(
            start: start,
            steps: steps.flatMap { Plausible.stepsPerMinute.contains($0) ? $0 : nil },
            activeCalories: calories.flatMap { Plausible.caloriesPerMinute.contains($0) ? $0 : nil },
            distanceMeters: distance.flatMap { Plausible.metersPerMinute.contains($0) ? $0 : nil },
            heartRate: heartRate.flatMap { Plausible.heartRate.contains($0) ? $0 : nil },
            oxygenSaturation: oxygen.flatMap { Plausible.oxygenSaturation.contains($0) ? $0 : nil },
            stress: stress.flatMap { $0 != stressNotMeasured && Plausible.stress.contains($0) ? $0 : nil }
        )
    }
}

/// Walks the value groups of one record, following the file header.
struct ValueGroups {
    private static let presentBit: UInt8 = 0b1000
    private static let nibblesPerByte = 2
    private static let nibbleMask: UInt8 = 0x0F
    private static let nibbleBits: UInt8 = 4
    private static let valuesPerGroup = 3

    private let header: [UInt8]
    private var index = -1
    private var width = 0
    private var current: UInt32 = 0

    init(header: [UInt8]) {
        self.header = header
    }

    /// Moves to the next group and reads it; false when the file does not carry
    /// that group, in which case no byte is consumed.
    mutating func next(bits: Int, from reader: inout ByteReader) throws(ActivityParseError) -> Bool {
        index += 1
        guard index < header.count * Self.nibblesPerByte else {
            // The header is too short for this layout: keep the reader aligned.
            _ = try Self.read(bits: bits, from: &reader)
            return false
        }
        guard nibble & Self.presentBit != 0 else {
            return false
        }
        width = bits
        current = try Self.read(bits: bits, from: &reader)
        return true
    }

    /// Whether the value at `position` (0, 1 or 2) of the current group is meaningful.
    func has(_ position: Int) -> Bool {
        guard (0..<Self.valuesPerGroup).contains(position) else { return false }
        return nibble & (1 << UInt8(Self.valuesPerGroup - 1 - position)) != 0
    }

    /// The `bits` wide value that starts `position` bits from the top of the group.
    func value(at position: Int, bits: Int) -> Int {
        let shift = width - position - bits
        guard shift >= 0, bits < UInt32.bitWidth else { return 0 }
        return Int(current >> UInt32(shift) & (1 << UInt32(bits) - 1))
    }

    private var nibble: UInt8 {
        guard index >= 0, index < header.count * Self.nibblesPerByte else { return 0 }
        let byte = header[index / Self.nibblesPerByte]
        return index.isMultiple(of: Self.nibblesPerByte) ? byte >> Self.nibbleBits : byte & Self.nibbleMask
    }

    private static func read(bits: Int, from reader: inout ByteReader) throws(ActivityParseError) -> UInt32 {
        switch bits {
        case 8: UInt32(try reader.byte())
        case 16: UInt32(try reader.uint16())
        default: try reader.uint32()
        }
    }
}
