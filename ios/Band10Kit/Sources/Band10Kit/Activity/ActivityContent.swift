// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.

import Foundation

/// The decoded content of an activity file.
public enum ActivityContent: Equatable, Sendable {
    case minutes([ActivityMinute])
    case summary(DailySummary)
    case sleep(SleepSession)
    case manualSamples([ManualSample])
    /// A well-formed file that holds nothing to record.
    case empty

    /// The kinds of file this library can read. Others are left on the band.
    public static func isSupported(_ kind: ActivityFileID.Kind) -> Bool {
        switch kind {
        case .dailyDetails, .dailySummary, .sleepStages, .manualSamples, .sleep: true
        case .workout, .unknown: false
        }
    }

    public static func decode(_ file: ActivityFile) throws(ActivityParseError) -> ActivityContent {
        switch file.id.kind {
        case .dailyDetails:
            return .minutes(try DailyDetails.parse(file))
        case .dailySummary:
            return .summary(try DailySummaryFile.parse(file))
        case .sleep:
            return .sleep(try SleepDetails.parse(file))
        case .sleepStages:
            return try SleepStagesFile.parse(file).map(ActivityContent.sleep) ?? .empty
        case .manualSamples:
            return .manualSamples(try ManualSamplesFile.parse(file))
        case .workout, .unknown:
            throw .unexpectedContent("unsupported file kind \(file.id.kind)")
        }
    }
}
