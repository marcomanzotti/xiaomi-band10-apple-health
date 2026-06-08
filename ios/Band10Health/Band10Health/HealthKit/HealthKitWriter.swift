import Foundation
import HealthKit

/// Writes detailed, segmented sleep data (plus optional HR / SpO2 / HRV /
/// respiratory samples) from a `SleepExport` into Apple Health.
///
/// The key thing Mi Fitness fails to do — and this fixes — is writing ONE
/// `HKCategorySample` per sleep stage with the correct subtype, instead of a
/// single undifferentiated "Asleep" block.
@MainActor
final class HealthKitWriter: ObservableObject {

    enum WriteError: LocalizedError {
        case unavailable
        case notAuthorized
        var errorDescription: String? {
            switch self {
            case .unavailable: return "HealthKit is not available on this device."
            case .notAuthorized: return "HealthKit write access was not granted."
            }
        }
    }

    private let store = HKHealthStore()

    // Types we write.
    private let sleepType = HKCategoryType(.sleepAnalysis)
    private let hrType = HKQuantityType(.heartRate)
    private let spo2Type = HKQuantityType(.oxygenSaturation)
    private let hrvType = HKQuantityType(.heartRateVariabilitySDNN)
    private let respType = HKQuantityType(.respiratoryRate)

    private var shareTypes: Set<HKSampleType> {
        [sleepType, hrType, spo2Type, hrvType, respType]
    }

    // MARK: Authorization

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw WriteError.unavailable }
        try await store.requestAuthorization(toShare: shareTypes, read: [])
    }

    // MARK: Stage mapping

    private func sleepValue(for stage: String) -> HKCategoryValueSleepAnalysis {
        switch stage.lowercased() {
        case "awake":   return .awake
        case "light":   return .asleepCore      // HealthKit has no separate "light"
        case "deep":    return .asleepDeep
        case "rem":     return .asleepREM
        default:        return .asleepUnspecified
        }
    }

    // MARK: Build samples

    /// Builds every HealthKit sample for one night without saving.
    func buildSamples(for night: Night) -> [HKSample] {
        var samples: [HKSample] = []

        // Overall "in bed" envelope for the whole session.
        samples.append(
            HKCategorySample(
                type: sleepType,
                value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                start: night.startDate,
                end: night.endDate,
                metadata: sharedMetadata(night)
            )
        )

        // One sample per stage segment.
        for seg in night.stages where seg.end > seg.start {
            samples.append(
                HKCategorySample(
                    type: sleepType,
                    value: sleepValue(for: seg.stage).rawValue,
                    start: seg.startDate,
                    end: seg.endDate,
                    metadata: sharedMetadata(night)
                )
            )
        }

        // Heart rate.
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        for s in night.heartRate ?? [] {
            samples.append(
                HKQuantitySample(
                    type: hrType,
                    quantity: HKQuantity(unit: bpmUnit, doubleValue: s.bpm),
                    start: s.date, end: s.date,
                    metadata: sharedMetadata(night)
                )
            )
        }

        // SpO2 (fraction 0–1).
        for s in night.spo2 ?? [] {
            samples.append(
                HKQuantitySample(
                    type: spo2Type,
                    quantity: HKQuantity(unit: .percent(), doubleValue: s.fraction),
                    start: s.date, end: s.date,
                    metadata: sharedMetadata(night)
                )
            )
        }

        // HRV (SDNN, milliseconds).
        for s in night.hrv ?? [] {
            samples.append(
                HKQuantitySample(
                    type: hrvType,
                    quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: s.ms),
                    start: s.date, end: s.date,
                    metadata: sharedMetadata(night)
                )
            )
        }

        // Respiratory rate (breaths/min).
        for s in night.respiratory ?? [] {
            samples.append(
                HKQuantitySample(
                    type: respType,
                    quantity: HKQuantity(unit: bpmUnit, doubleValue: s.brpm),
                    start: s.date, end: s.date,
                    metadata: sharedMetadata(night)
                )
            )
        }

        return samples
    }

    private func sharedMetadata(_ night: Night) -> [String: Any] {
        var md: [String: Any] = [HKMetadataKeyWasUserEntered: false]
        if let score = night.score { md["sleepScore"] = score }
        md["importSource"] = "xiaomi-band10"
        return md
    }

    // MARK: Save

    /// Saves all samples for an entire export. Returns count of samples written.
    @discardableResult
    func save(export: SleepExport) async throws -> Int {
        let samples = export.nights.flatMap { buildSamples(for: $0) }
        guard !samples.isEmpty else { return 0 }
        try await store.save(samples)
        return samples.count
    }
}
