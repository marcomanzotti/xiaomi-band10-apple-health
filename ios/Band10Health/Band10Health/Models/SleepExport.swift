import Foundation

/// Decodable model matching the JSON emitted by the Python fetcher
/// (see fetcher/band10/sleep_model.py). This is the contract between the two halves.
struct SleepExport: Codable {
    let version: Int
    let source: String
    let nights: [Night]
}

struct Night: Codable {
    let date: String
    let timezone: String
    let start: Int          // epoch seconds, session start (in bed)
    let end: Int            // epoch seconds, session end
    let score: Int?
    let stages: [Stage]
    let heartRate: [HRSample]?
    let spo2: [SpO2Sample]?
    let hrv: [HRVSample]?
    let respiratory: [RespSample]?

    enum CodingKeys: String, CodingKey {
        case date, timezone, start, end, score, stages
        case heartRate = "heart_rate"
        case spo2, hrv, respiratory
    }

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(start)) }
    var endDate: Date { Date(timeIntervalSince1970: TimeInterval(end)) }
}

struct Stage: Codable {
    let start: Int
    let end: Int
    let stage: String       // awake | light | deep | rem | unknown

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(start)) }
    var endDate: Date { Date(timeIntervalSince1970: TimeInterval(end)) }
}

struct HRSample: Codable {
    let t: Int
    let bpm: Double
    var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }
}

struct SpO2Sample: Codable {
    let t: Int
    let pct: Double         // percent, e.g. 96.0
    var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }
    /// HealthKit expects a fraction 0.0–1.0 for oxygenSaturation.
    var fraction: Double { pct / 100.0 }
}

struct HRVSample: Codable {
    let t: Int
    let ms: Double          // SDNN in milliseconds
    var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }
}

struct RespSample: Codable {
    let t: Int
    let brpm: Double        // breaths per minute
    var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }
}
