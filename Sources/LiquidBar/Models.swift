import Foundation

enum AppVersion {
    static let current = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "development"
}

enum PresetID: String, Codable, CaseIterable, Identifiable {
    case quiet
    case daily
    case performance
    case full

    var id: String { rawValue }
}

struct CoolingPreset: Codable, Equatable {
    var fanDuty: Int
    var pumpDuty: Int
}

struct AlertThresholds: Codable, Equatable {
    var cpuWarning: Double = 80
    var cpuCritical: Double = 90
    var liquidWarning: Double = 45
    var liquidCritical: Double = 50
    var triggerDelay: TimeInterval = 15
    var hysteresis: Double = 3
    var recoveryDelay: TimeInterval = 60
}

struct AppSettings: Codable, Equatable {
    var launchAtLogin = true
    // Optional for backward-compatible decoding of settings written by older versions.
    var showLiquidTemperatureInMenuBar: Bool? = false
    var notificationsEnabled = false
    var criticalSoundEnabled = true
    var automaticEmergencyBoost = false
    var linkedFans = false
    var fanNames = ["Fan 1", "Fan 2", "Fan 3"]
    var presets: [PresetID: CoolingPreset] = [
        .quiet: CoolingPreset(fanDuty: 35, pumpDuty: 60),
        .daily: CoolingPreset(fanDuty: 50, pumpDuty: 70),
        .performance: CoolingPreset(fanDuty: 75, pumpDuty: 90),
        .full: CoolingPreset(fanDuty: 100, pumpDuty: 100),
    ]
    var thresholds = AlertThresholds()
    var lastPreset: PresetID? = .daily
    var manualFanDuty = [50, 50, 50]
    var manualPumpDuty = 70

    mutating func sanitize() {
        showLiquidTemperatureInMenuBar = showLiquidTemperatureInMenuBar ?? false
        fanNames = Array((fanNames + ["Fan 1", "Fan 2", "Fan 3"]).prefix(3))
        manualFanDuty = Array((manualFanDuty + [50, 50, 50]).prefix(3)).map {
            min(100, max(30, $0))
        }
        manualPumpDuty = min(100, max(50, manualPumpDuty))
        for id in PresetID.allCases {
            let fallback = AppSettings.defaultPreset(id)
            let preset = presets[id] ?? fallback
            presets[id] = CoolingPreset(
                fanDuty: min(100, max(30, preset.fanDuty)),
                pumpDuty: min(100, max(50, preset.pumpDuty))
            )
        }
    }

    static func defaultPreset(_ id: PresetID) -> CoolingPreset {
        switch id {
        case .quiet: return CoolingPreset(fanDuty: 35, pumpDuty: 60)
        case .daily: return CoolingPreset(fanDuty: 50, pumpDuty: 70)
        case .performance: return CoolingPreset(fanDuty: 75, pumpDuty: 90)
        case .full: return CoolingPreset(fanDuty: 100, pumpDuty: 100)
        }
    }
}

struct DeviceSnapshot: Codable, Equatable {
    var timestamp = Date()
    var liquidTemperature: Double?
    var pumpRPM: Int?
    var pumpDuty: Int?
    var fanRPM: [Int?] = [nil, nil, nil]
    var fanDuty: [Int?] = [nil, nil, nil]
    var fanModes: [String?] = [nil, nil, nil]
    var noiseLevel: Int?
    var connected = false

    static let unavailable = DeviceSnapshot(
        liquidTemperature: nil,
        pumpRPM: nil,
        pumpDuty: nil,
        connected: false
    )

}

struct HistorySample: Codable, Identifiable, Equatable {
    var id: Date { timestamp }
    let timestamp: Date
    let cpuTemperature: Double?
    let liquidTemperature: Double?
    let fanRPM: [Int?]
    let pumpRPM: Int?
}

enum AlertSeverity: Int, Codable, Comparable {
    case normal = 0
    case warning = 1
    case critical = 2

    static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ChartRange: TimeInterval, CaseIterable, Identifiable {
    case fifteenMinutes = 900
    case oneHour = 3_600
    case sixHours = 21_600
    case oneDay = 86_400

    var id: TimeInterval { rawValue }
    var label: String {
        switch self {
        case .fifteenMinutes: return "15m"
        case .oneHour: return "1h"
        case .sixHours: return "6h"
        case .oneDay: return "24h"
        }
    }
}
