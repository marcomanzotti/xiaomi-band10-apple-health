// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.

import Foundation

/// One value ready to be written to a health store, independent of HealthKit so
/// that the mapping can be tested anywhere.
public struct HealthSample: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Count.
        case steps
        /// Kilocalories.
        case activeEnergy
        /// Metres walked or run.
        case distance
        /// Beats per minute.
        case heartRate
        /// Beats per minute.
        case restingHeartRate
        /// Fraction between 0 and 1.
        case oxygenSaturation
        /// No value: the stage lasts from `start` to `end`.
        case sleep(SleepStage)
    }

    public let kind: Kind
    public let value: Double
    public let start: Date
    public let end: Date
    /// Identifies the measurement across syncs, so that a file received twice
    /// does not produce duplicates.
    public let syncIdentifier: String
    /// A sample replaces a stored one with the same identifier only when this is higher.
    public let syncVersion: Int

    public init(kind: Kind, value: Double, start: Date, end: Date, syncIdentifier: String, syncVersion: Int) {
        self.kind = kind
        self.value = value
        self.start = start
        self.end = end
        self.syncIdentifier = syncIdentifier
        self.syncVersion = syncVersion
    }
}

public enum HealthSamples {
    private static let identifierPrefix = "band10"
    private static let percent = 100.0
    private static let fixedVersion = 1

    /// - Parameter revision: a number that grows from one sync to the next, used
    ///   for values the band may revise later (the day's resting heart rate).
    public static func make(from content: ActivityContent, revision: Int) -> [HealthSample] {
        switch content {
        case .minutes(let minutes):
            return minutes.flatMap(samples(for:))
        case .summary(let summary):
            return samples(for: summary, revision: revision)
        case .sleep(let session):
            return samples(for: session)
        case .manualSamples(let manual):
            return manual.compactMap(sample(for:))
        case .empty:
            return []
        }
    }

    private static func samples(for minute: ActivityMinute) -> [HealthSample] {
        let end = minute.start.addingTimeInterval(DailyDetails.secondsPerMinute)
        // Totals only grow while their minute is still running, so the value
        // itself tells a newer reading from an older one.
        let totals: [(HealthSample.Kind, String, Int?)] = [
            (.steps, "steps", minute.steps),
            (.activeEnergy, "energy", minute.activeCalories),
            (.distance, "distance", minute.distanceMeters),
        ]
        let cumulative = totals.compactMap { kind, name, value in
            value.map {
                HealthSample(
                    kind: kind, value: Double($0), start: minute.start, end: end,
                    syncIdentifier: identifier(name, minute.start), syncVersion: $0
                )
            }
        }
        let heartRate = minute.heartRate.map {
            instant(.heartRate, "hr", Double($0), at: minute.start)
        }
        let oxygen = minute.oxygenSaturation.map {
            instant(.oxygenSaturation, "spo2", Double($0) / percent, at: minute.start)
        }
        return cumulative + [heartRate, oxygen].compactMap { $0 }
    }

    private static func samples(for summary: DailySummary, revision: Int) -> [HealthSample] {
        guard let resting = summary.restingHeartRate else { return [] }
        return [
            HealthSample(
                kind: .restingHeartRate, value: Double(resting), start: summary.day, end: summary.day,
                syncIdentifier: identifier("resting-hr", summary.day), syncVersion: revision
            ),
        ]
    }

    /// A night still in progress is written too: each stage is keyed by its start
    /// and versioned by its end, so the complete night sent later extends it.
    private static func samples(for session: SleepSession) -> [HealthSample] {
        session.segments.map { segment in
            HealthSample(
                kind: .sleep(segment.stage), value: 0, start: segment.start, end: segment.end,
                syncIdentifier: identifier("sleep", segment.start),
                syncVersion: Int(segment.end.timeIntervalSince1970)
            )
        }
    }

    private static func sample(for manual: ManualSample) -> HealthSample? {
        switch manual.kind {
        case .heartRate:
            instant(.heartRate, "manual-hr", Double(manual.value), at: manual.date)
        case .oxygenSaturation:
            instant(.oxygenSaturation, "manual-spo2", Double(manual.value) / percent, at: manual.date)
        case .stress:
            // Health has no stress type.
            nil
        }
    }

    private static func instant(_ kind: HealthSample.Kind, _ name: String, _ value: Double, at date: Date) -> HealthSample {
        HealthSample(
            kind: kind, value: value, start: date, end: date,
            syncIdentifier: identifier(name, date), syncVersion: fixedVersion
        )
    }

    private static func identifier(_ name: String, _ date: Date) -> String {
        "\(identifierPrefix).\(name).\(Int(date.timeIntervalSince1970))"
    }
}
