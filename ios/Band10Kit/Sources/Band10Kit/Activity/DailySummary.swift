// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Layout derived from Gadgetbridge (DailySummaryParser), AGPL-3.0.

import Foundation

/// The band's own totals for one day. A value the band marked as absent is nil.
public struct DailySummary: Equatable, Sendable {
    public let day: Date
    public let steps: Int?
    /// Active energy in kilocalories.
    public let activeCalories: Int?
    /// Total energy in kilocalories.
    public let totalCalories: Int?
    public let restingHeartRate: Int?
    public let maximumHeartRate: Int?
    public let minimumHeartRate: Int?
    public let averageHeartRate: Int?
    public let averageOxygenSaturation: Int?
    public let averageStress: Int?
}

public enum DailySummaryFile {
    /// The fields of the file, in order: each one is always present and has a
    /// fixed width; a bit in the header says whether its value is meaningful.
    private enum Slot: Int, CaseIterable {
        case steps, activeCalories, reserved2, restingHeartRate, maximumHeartRate, maximumHeartRateTime
        case minimumHeartRate, minimumHeartRateTime, averageHeartRate, averageStress, maximumStress, minimumStress
        case standingHours, totalCalories, recoveryHours, reserved15, maximumOxygen, maximumOxygenTime
        case minimumOxygen, minimumOxygenTime, averageOxygen, trainingLoadDay, trainingLoadWeek, trainingLoadLevel
        case vitalityLight, vitalityModerate, vitalityHigh, vitalityCurrent, reserved28, reserved29
        case reserved30, reserved31

        var width: Int {
            switch self {
            case .steps, .maximumHeartRateTime, .minimumHeartRateTime, .maximumOxygenTime, .minimumOxygenTime: 4
            case .standingHours: 3
            case .activeCalories, .totalCalories, .recoveryHours, .trainingLoadDay, .trainingLoadWeek,
                 .vitalityCurrent, .reserved30, .reserved31: 2
            default: 1
            }
        }
    }

    private static let plausibleHeartRate = 25...240
    private static let plausibleOxygenSaturation = 60...100
    private static let plausibleStress = 1...100

    public static func parse(_ file: ActivityFile) throws(ActivityParseError) -> DailySummary {
        let layout = try layout(version: file.id.version)
        var reader = ByteReader(file.content)
        let validity = ValidityBitmap(header: try reader.take(layout.headerLength))
        var values: [Slot: Int] = [:]
        for slot in Slot.allCases.prefix(layout.slotCount) {
            // The Band 10 ends its file before the last reserved slots, which the
            // Gadgetbridge layout reads from the checksum: a slot that does not
            // fit is absent.
            guard reader.remaining >= slot.width else { break }
            let raw = try reader.take(slot.width).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            if validity.isValid(slot.rawValue) {
                values[slot] = raw
            }
        }
        return DailySummary(
            day: file.id.date,
            steps: values[.steps],
            activeCalories: values[.activeCalories],
            totalCalories: values[.totalCalories],
            restingHeartRate: values[.restingHeartRate].flatMap(heartRate),
            maximumHeartRate: values[.maximumHeartRate].flatMap(heartRate),
            minimumHeartRate: values[.minimumHeartRate].flatMap(heartRate),
            averageHeartRate: values[.averageHeartRate].flatMap(heartRate),
            averageOxygenSaturation: values[.averageOxygen].flatMap { plausibleOxygenSaturation.contains($0) ? $0 : nil },
            averageStress: values[.averageStress].flatMap { plausibleStress.contains($0) ? $0 : nil }
        )
    }

    private static func heartRate(_ value: Int) -> Int? {
        plausibleHeartRate.contains(value) ? value : nil
    }

    private static func layout(version: Int) throws(ActivityParseError) -> (headerLength: Int, slotCount: Int) {
        switch version {
        case 3, 4: (3, 21)
        case 5: (4, 32)
        default: throw .unsupportedVersion(version)
        }
    }
}
