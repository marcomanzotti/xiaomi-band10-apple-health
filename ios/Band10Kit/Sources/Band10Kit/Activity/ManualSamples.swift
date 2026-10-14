// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Layout derived from Gadgetbridge (ManualSamplesParser), AGPL-3.0.

import Foundation

/// A measurement the wearer started by hand on the band.
public struct ManualSample: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heartRate
        case oxygenSaturation
        case stress
    }

    public let kind: Kind
    public let date: Date
    public let value: Int

    public init(kind: Kind, date: Date, value: Int) {
        self.kind = kind
        self.date = date
        self.value = value
    }
}

/// Reads the spot-measurement file: a run of `time (4) | type (1) | value`.
public enum ManualSamplesFile {
    private enum SampleType {
        static let heartRate: UInt8 = 0x11
        static let oxygenSaturation: UInt8 = 0x12
        static let stress: UInt8 = 0x13
        /// Skin temperature: two 2-byte values, not written to Health.
        static let temperature: UInt8 = 0x44
        static let temperatureWidth = 4
    }

    private enum LegacyType {
        static let oxygenSaturation: UInt8 = 0x02
        static let stress: UInt8 = 0x03
    }

    private static let legacyVersion = 1
    private static let currentVersion = 2
    private static let legacyHeader: UInt8 = 0xFF
    private static let plausibleHeartRate = 25...240
    private static let plausiblePercent = 1...100

    public static func parse(_ file: ActivityFile) throws(ActivityParseError) -> [ManualSample] {
        var reader = ByteReader(file.content)
        switch file.id.version {
        case legacyVersion:
            guard try reader.byte() == legacyHeader else {
                throw .unexpectedContent("manual samples header")
            }
            return try readSamples(from: &reader, kindOf: legacyKind)
        case currentVersion:
            return try readSamples(from: &reader, kindOf: currentKind)
        default:
            throw .unsupportedVersion(file.id.version)
        }
    }

    /// `kindOf` returns nil for a type whose value must be skipped, and throws for
    /// a type of unknown width, after which the rest of the file cannot be read.
    private static func readSamples(
        from reader: inout ByteReader,
        kindOf: (UInt8, inout ByteReader) throws(ActivityParseError) -> ManualSample.Kind?
    ) throws(ActivityParseError) -> [ManualSample] {
        var samples: [ManualSample] = []
        while !reader.isAtEnd {
            let date = Date(timeIntervalSince1970: TimeInterval(try reader.uint32()))
            guard let kind = try kindOf(try reader.byte(), &reader) else { continue }
            let value = Int(try reader.byte())
            if isPlausible(value, for: kind) {
                samples.append(ManualSample(kind: kind, date: date, value: value))
            }
        }
        return samples
    }

    private static func currentKind(
        _ type: UInt8, _ reader: inout ByteReader
    ) throws(ActivityParseError) -> ManualSample.Kind? {
        switch type {
        case SampleType.heartRate: return .heartRate
        case SampleType.oxygenSaturation: return .oxygenSaturation
        case SampleType.stress: return .stress
        case SampleType.temperature:
            try reader.skip(SampleType.temperatureWidth)
            return nil
        default:
            throw .unexpectedContent("manual sample type \(type)")
        }
    }

    private static func legacyKind(
        _ type: UInt8, _ reader: inout ByteReader
    ) throws(ActivityParseError) -> ManualSample.Kind? {
        switch type {
        case LegacyType.oxygenSaturation: .oxygenSaturation
        case LegacyType.stress: .stress
        default: throw .unexpectedContent("manual sample type \(type)")
        }
    }

    private static func isPlausible(_ value: Int, for kind: ManualSample.Kind) -> Bool {
        switch kind {
        case .heartRate: plausibleHeartRate.contains(value)
        case .oxygenSaturation, .stress: plausiblePercent.contains(value)
        }
    }
}
