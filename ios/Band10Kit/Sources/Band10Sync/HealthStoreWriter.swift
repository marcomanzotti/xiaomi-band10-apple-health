// Band10Sync — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.

import Band10Kit
import Foundation
import HealthKit

public enum HealthAccess: Equatable, Sendable {
    /// Health is not available on this device.
    case unavailable
    /// The user has not been asked yet: nothing can be written.
    case notRequested
    /// The user answered: `allowed` of the `total` data types may be written.
    /// On iOS the permission sheet starts with every type switched off, so a
    /// quick "Allow" can leave this at zero.
    case answered(allowed: Int, total: Int)

    public var allowsWriting: Bool {
        if case .answered(let allowed, _) = self { allowed > 0 } else { false }
    }
}

/// Writes the band's measurements to Apple Health. Every sample carries a sync
/// identifier, so writing the same measurement twice leaves a single entry.
public struct HealthStoreWriter: Sendable {
    private static let batchSize = 2000
    private static let beatsPerMinute = HKUnit.count().unitDivided(by: .minute())
    private static let device = HKDevice(
        name: "Xiaomi Smart Band 10", manufacturer: "Xiaomi", model: "Smart Band 10",
        hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil
    )
    private static let writtenTypes: [HKSampleType] = [
        HKQuantityType(.stepCount),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.heartRate),
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.oxygenSaturation),
        HKCategoryType(.sleepAnalysis),
    ]

    private let store = HKHealthStore()

    public init() {}

    public var access: HealthAccess {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let statuses = Self.writtenTypes.map { store.authorizationStatus(for: $0) }
        guard !statuses.contains(.notDetermined) else { return .notRequested }
        return .answered(allowed: statuses.filter { $0 == .sharingAuthorized }.count, total: statuses.count)
    }

    /// Names of the data types the user switched off, for the diary and the settings screen.
    public var switchedOffTypes: [String] {
        Self.writtenTypes.filter { store.authorizationStatus(for: $0) == .sharingDenied }.map(Self.name(of:))
    }

    private static func name(of type: HKSampleType) -> String {
        switch type {
        case HKQuantityType(.stepCount): "passi"
        case HKQuantityType(.activeEnergyBurned): "energia attiva"
        case HKQuantityType(.distanceWalkingRunning): "distanza"
        case HKQuantityType(.heartRate): "battito"
        case HKQuantityType(.restingHeartRate): "battito a riposo"
        case HKQuantityType(.oxygenSaturation): "SpO₂"
        case HKCategoryType(.sleepAnalysis): "sonno"
        default: type.identifier
        }
    }

    /// Shows the system's permission sheet. Only works while the app is on screen.
    public func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: Set(Self.writtenTypes), read: [])
    }

    public struct WriteResult: Equatable, Sendable {
        public var written = 0
        /// Values Health refused because writing that type is not allowed.
        public var refused = 0
        /// The refused types and Health's reason, for the diary.
        public var refusals: [String] = []
    }

    /// Writes the samples type by type and reports what Health accepted. The
    /// permission status iOS reports is not trusted: each type is attempted, and
    /// only Health's own refusal counts as "not allowed". Throws when Health
    /// cannot be written right now, for example while the phone is locked: the
    /// caller should try again later.
    public func write(_ samples: [HealthSample]) async throws -> WriteResult {
        let objects = samples.compactMap(object(for:))
        let byType = Dictionary(grouping: objects) { $0.sampleType.identifier }
        var result = WriteResult()
        for group in byType.values {
            do {
                for start in stride(from: 0, to: group.count, by: Self.batchSize) {
                    try await store.save(Array(group[start..<min(start + Self.batchSize, group.count)]))
                }
                result.written += group.count
            } catch let error as HKError where error.code == .errorAuthorizationDenied || error.code == .errorAuthorizationNotDetermined {
                result.refused += group.count
                let name = group.first.map { Self.name(of: $0.sampleType) } ?? "?"
                result.refusals.append("\(name) (\(error.code.rawValue))")
            }
        }
        return result
    }

    private func object(for sample: HealthSample) -> HKSample? {
        let metadata: [String: Any] = [
            HKMetadataKeySyncIdentifier: sample.syncIdentifier,
            HKMetadataKeySyncVersion: sample.syncVersion,
            HKMetadataKeyWasUserEntered: false,
        ]
        if case .sleep(let stage) = sample.kind {
            let type = HKCategoryType(.sleepAnalysis)
            return HKCategorySample(
                type: type, value: Self.sleepValue(stage).rawValue,
                start: sample.start, end: sample.end, device: Self.device, metadata: metadata
            )
        }
        guard let (type, unit) = Self.quantity(for: sample.kind) else { return nil }
        return HKQuantitySample(
            type: type, quantity: HKQuantity(unit: unit, doubleValue: sample.value),
            start: sample.start, end: sample.end, device: Self.device, metadata: metadata
        )
    }

    private static func quantity(for kind: HealthSample.Kind) -> (HKQuantityType, HKUnit)? {
        switch kind {
        case .steps: (HKQuantityType(.stepCount), .count())
        case .activeEnergy: (HKQuantityType(.activeEnergyBurned), .kilocalorie())
        case .distance: (HKQuantityType(.distanceWalkingRunning), .meter())
        case .heartRate: (HKQuantityType(.heartRate), beatsPerMinute)
        case .restingHeartRate: (HKQuantityType(.restingHeartRate), beatsPerMinute)
        case .oxygenSaturation: (HKQuantityType(.oxygenSaturation), .percent())
        case .sleep: nil
        }
    }

    /// Health has no "light" stage: Apple calls it core sleep.
    private static func sleepValue(_ stage: SleepStage) -> HKCategoryValueSleepAnalysis {
        switch stage {
        case .awake: .awake
        case .light: .asleepCore
        case .deep: .asleepDeep
        case .rem: .asleepREM
        }
    }
}
