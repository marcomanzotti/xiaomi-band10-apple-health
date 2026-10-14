// Band10Sync — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.

import Band10Kit
import Foundation
import HealthKit

public enum HealthAccess: Equatable, Sendable {
    /// Health is not available on this device.
    case unavailable
    /// The user has not been asked yet: nothing can be written.
    case notRequested
    /// The user answered; individual data types may still be switched off.
    case requested
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
        let isUndecided = Self.writtenTypes.contains { store.authorizationStatus(for: $0) == .notDetermined }
        return isUndecided ? .notRequested : .requested
    }

    /// Shows the system's permission sheet. Only works while the app is on screen.
    public func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: Set(Self.writtenTypes), read: [])
    }

    /// Writes the samples of the types the user allowed and returns how many
    /// were written. Throws when Health cannot be written right now, for example
    /// while the phone is locked: the caller should try again later.
    @discardableResult
    public func write(_ samples: [HealthSample]) async throws -> Int {
        let objects = samples.compactMap(object(for:))
        for start in stride(from: 0, to: objects.count, by: Self.batchSize) {
            try await store.save(Array(objects[start..<min(start + Self.batchSize, objects.count)]))
        }
        return objects.count
    }

    private func object(for sample: HealthSample) -> HKObject? {
        let metadata: [String: Any] = [
            HKMetadataKeySyncIdentifier: sample.syncIdentifier,
            HKMetadataKeySyncVersion: sample.syncVersion,
            HKMetadataKeyWasUserEntered: false,
        ]
        if case .sleep(let stage) = sample.kind {
            let type = HKCategoryType(.sleepAnalysis)
            guard store.authorizationStatus(for: type) == .sharingAuthorized else { return nil }
            return HKCategorySample(
                type: type, value: Self.sleepValue(stage).rawValue,
                start: sample.start, end: sample.end, device: Self.device, metadata: metadata
            )
        }
        guard let (type, unit) = Self.quantity(for: sample.kind),
              store.authorizationStatus(for: type) == .sharingAuthorized
        else { return nil }
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
