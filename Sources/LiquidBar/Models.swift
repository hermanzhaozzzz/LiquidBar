import Foundation

enum AppVersion {
    static let current = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "development"
    static let build = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
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
    var radiatorDuty: Int?
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

enum SamplingProfile: String, Codable, CaseIterable, Identifiable {
    case fast
    case balanced
    case eco

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: return L10n.text("samplingFast")
        case .balanced: return L10n.text("samplingBalanced")
        case .eco: return L10n.text("samplingEco")
        }
    }

    var telemetryInterval: TimeInterval {
        switch self {
        case .fast: return 1
        case .balanced: return 2
        case .eco: return 4
        }
    }

    func deviceInterval(popoverOpen: Bool) -> TimeInterval {
        switch self {
        case .fast: return popoverOpen ? 1 : 3
        case .balanced: return popoverOpen ? 2 : 5
        case .eco: return popoverOpen ? 3 : 6
        }
    }
}

enum MenuBarTemperatureDisplay: String, Codable, CaseIterable, Identifiable {
    case cpu
    case gpu
    case cpuAndGPU

    var id: String { rawValue }
}

enum MenuBarSensor: String {
    case cpu, gpu, liquid

    var symbol: String? {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return nil
        case .liquid: return "drop.fill"
        }
    }

    var label: String {
        self == .liquid ? L10n.text("liquid") : rawValue.uppercased()
    }
}

struct MenuBarTemperatureItem: Identifiable, Equatable {
    var id: MenuBarSensor { sensor }
    let sensor: MenuBarSensor
    let temperature: Double?
    let level: AlertSeverity?

    // Visual reference for the driver's edge-temperature reading only.
    // These values do not participate in notifications or fan-control policies.
    static let gpuWarm = 70.0
    static let gpuHot = 85.0

    init(sensor: MenuBarSensor, temperature: Double?, thresholds: AlertThresholds) {
        self.sensor = sensor
        guard let temperature, temperature.isFinite else {
            self.temperature = nil
            level = nil
            return
        }
        self.temperature = temperature
        let warning: Double
        let critical: Double
        switch sensor {
        case .cpu: (warning, critical) = (thresholds.cpuWarning, thresholds.cpuCritical)
        case .gpu: (warning, critical) = (Self.gpuWarm, Self.gpuHot)
        case .liquid: (warning, critical) = (thresholds.liquidWarning, thresholds.liquidCritical)
        }
        level = temperature >= critical ? .critical : (temperature >= warning ? .warning : .normal)
    }

    var formattedTemperature: String {
        temperature.map { String(format: "%.0f°", $0) } ?? "--°"
    }

    var accessibilityText: String { "\(sensor.label) \(formattedTemperature)" }
}

struct AppSettings: Codable, Equatable {
    var launchAtLogin = true
    // Optional for backward-compatible decoding of settings written by older versions.
    var showLiquidTemperatureInMenuBar: Bool? = false
    var menuBarTemperatureDisplay: MenuBarTemperatureDisplay? = .cpu
    var samplingProfile: SamplingProfile? = .balanced
    var setupCompleted: Bool? = false
    var lastPermissionPromptFingerprint: String?
    var notificationsEnabled = false
    var criticalSoundEnabled = true
    var automaticEmergencyBoost = false
    var linkedFans = false
    var fanNames = ["Fan 1", "Fan 2", "Fan 3"]
    var presets: [PresetID: CoolingPreset] = [
        .quiet: CoolingPreset(fanDuty: 35, pumpDuty: 60, radiatorDuty: 40),
        .daily: CoolingPreset(fanDuty: 50, pumpDuty: 70, radiatorDuty: 55),
        .performance: CoolingPreset(fanDuty: 75, pumpDuty: 90, radiatorDuty: 80),
        .full: CoolingPreset(fanDuty: 100, pumpDuty: 100, radiatorDuty: 100),
    ]
    var thresholds = AlertThresholds()
    var lastPreset: PresetID? = .daily
    var manualFanDuty = [50, 50, 50]
    var manualPumpDuty = 70
    var pumpAutomatic: Bool? = false
    var fanCurve: FanCurveSettings?
    var lighting: [String: LightingSettings]?
    var showLightingInPanel: Bool? = false
    var display: DisplaySettings?
    var motherboardMapping: MotherboardMappingSettings?
    var temporaryMotherboardControl: Bool?

    mutating func sanitize() {
        showLiquidTemperatureInMenuBar = showLiquidTemperatureInMenuBar ?? false
        menuBarTemperatureDisplay = menuBarTemperatureDisplay ?? .cpu
        samplingProfile = samplingProfile ?? .balanced
        setupCompleted = setupCompleted ?? false
        fanNames = Array((fanNames + ["Fan 1", "Fan 2", "Fan 3"]).prefix(3))
        manualFanDuty = Array((manualFanDuty + [50, 50, 50]).prefix(3)).map {
            min(100, max(30, $0))
        }
        manualPumpDuty = min(100, max(50, manualPumpDuty))
        pumpAutomatic = pumpAutomatic ?? false
        showLightingInPanel = showLightingInPanel ?? false
        if var curve = fanCurve { curve.sanitize(); fanCurve = curve }
        for id in PresetID.allCases {
            let fallback = AppSettings.defaultPreset(id)
            let preset = presets[id] ?? fallback
            presets[id] = CoolingPreset(
                fanDuty: min(100, max(30, preset.fanDuty)),
                pumpDuty: min(100, max(50, preset.pumpDuty)),
                radiatorDuty: min(100, max(30, preset.radiatorDuty ?? fallback.radiatorDuty ?? 55))
            )
        }
    }

    static func defaultPreset(_ id: PresetID) -> CoolingPreset {
        switch id {
        case .quiet: return CoolingPreset(fanDuty: 35, pumpDuty: 60, radiatorDuty: 40)
        case .daily: return CoolingPreset(fanDuty: 50, pumpDuty: 70, radiatorDuty: 55)
        case .performance: return CoolingPreset(fanDuty: 75, pumpDuty: 90, radiatorDuty: 80)
        case .full: return CoolingPreset(fanDuty: 100, pumpDuty: 100, radiatorDuty: 100)
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
    var devices: [String: DeviceCapability] = [:]
    var errors: [String: String] = [:]

    func supports(_ role: String, _ capability: String) -> Bool {
        devices[role]?.connected == true && devices[role]?.capabilities.contains(capability) == true
    }

    var hasSmart: Bool { supports("smart", "fan_control") }
    var hasPump: Bool { supports("kraken", "pump_control") }
    var hasLiquidSensor: Bool { supports("kraken", "liquid_temperature") }
    var hasCoolingControl: Bool { hasSmart || hasPump }

    // A failed detected device keeps its diagnostic row; absent optional hardware
    // contributes no placeholder. Capability availability separately gates controls.
    var visibleDeviceRoles: [String] {
        ["smart", "aura", "ld", "kraken"].filter { role in
            devices[role]?.connected == true || devices[role]?.error != nil
        }
    }

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
    // Optional so history written before GPU monitoring still decodes.
    var gpuTemperature: Double?
    var gpuFanRPM: Int?
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

struct DeviceCapability: Codable, Equatable {
    var connected: Bool
    var capabilities: [String]
    var channels: [String]
    var error: String?
}

struct FanCurveSettings: Codable, Equatable {
    var enabled = false
    var coolTemperature = 40.0
    var hotTemperature = 80.0
    var minimumDuty = 35
    var maximumDuty = 100

    mutating func sanitize() {
        coolTemperature = coolTemperature.isFinite ? min(75, max(25, coolTemperature)) : 40
        hotTemperature = hotTemperature.isFinite ? min(90, max(coolTemperature + 5, hotTemperature)) : 80
        minimumDuty = min(100, max(30, minimumDuty))
        maximumDuty = min(100, max(minimumDuty, maximumDuty))
    }

    func duty(for temperature: Double?) -> Int {
        guard let temperature, temperature.isFinite else { return 100 }
        if temperature >= 90 { return 100 }
        let fraction = min(1, max(0, (temperature - coolTemperature) / max(1, hotTemperature - coolTemperature)))
        return Int((Double(minimumDuty) + fraction * Double(maximumDuty - minimumDuty)).rounded())
    }
}

struct LightingSettings: Codable, Equatable {
    var channel = "sync"
    var mode = "fixed"
    var red = 0.0
    var green = 0.5
    var blue = 1.0
    var brightness = 1.0

    var rgb: [Int] {
        [red, green, blue].map { value in
            let component = value.isFinite ? min(1, max(0, value)) : 0
            let level = brightness.isFinite ? min(1, max(0, brightness)) : 1
            return Int((component * level * 255).rounded())
        }
    }
}

struct DisplaySettings: Codable, Equatable {
    var enabled = false
    var unit = "C"
}

struct MotherboardMappingSettings: Codable, Equatable {
    var cpuIndex: Int?
    var pumpIndex: Int?
    var confirmed = false
    // CPU-only confirmation is tied to the physical channel, not pump permission.
    // Older settings retain their explicitly confirmed combined mapping.
    var confirmedCPUIndex: Int?

    func confirmedIndex(for role: MotherboardFanRole) -> Int? {
        guard let index = role == .cpu ? cpuIndex : pumpIndex,
              (0..<7).contains(index), cpuIndex != pumpIndex else { return nil }
        guard confirmed || (role == .cpu && confirmedCPUIndex == index) else { return nil }
        return index
    }
}
