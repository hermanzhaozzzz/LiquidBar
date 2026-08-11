import Foundation
import Testing
@testable import LiquidBar

@Test
func defaultPresetsAndSafetyLimits() {
    var settings = AppSettings()
    #expect(settings.showLiquidTemperatureInMenuBar == false)
    #expect(settings.presets[.quiet] == CoolingPreset(fanDuty: 35, pumpDuty: 60))
    #expect(settings.presets[.daily] == CoolingPreset(fanDuty: 50, pumpDuty: 70))
    #expect(settings.presets[.performance] == CoolingPreset(fanDuty: 75, pumpDuty: 90))
    #expect(settings.presets[.full] == CoolingPreset(fanDuty: 100, pumpDuty: 100))

    settings.manualFanDuty = [0, 101, 20]
    settings.manualPumpDuty = 10
    settings.sanitize()
    #expect(settings.manualFanDuty == [30, 100, 30])
    #expect(settings.manualPumpDuty == 50)
}

@Test
func olderSettingsDecodeWithoutMenuBarPreference() throws {
    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any]
    )
    object.removeValue(forKey: "showLiquidTemperatureInMenuBar")

    var decoded = try JSONDecoder().decode(
        AppSettings.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    decoded.sanitize()

    #expect(decoded.showLiquidTemperatureInMenuBar == false)
    #expect(decoded.presets[.performance] == CoolingPreset(fanDuty: 75, pumpDuty: 90))
}

@Test @MainActor
func menuBarShowsOnlyTemperaturesSelectedByTheUser() {
    let defaultText = AppModel.formatMenuBarText(
        cpuTemperature: 58.2,
        liquidTemperature: 38.2,
        showLiquidTemperature: false
    )
    #expect(defaultText == "CPU 58°")

    let liquidText = AppModel.formatMenuBarText(
        cpuTemperature: 58.2,
        liquidTemperature: 38.2,
        showLiquidTemperature: true
    )
    #expect(liquidText.contains("CPU 58°"))
    #expect(liquidText.contains("38°"))
    #expect(!liquidText.contains("RPM"))
}

@Test
func thermalSeverityUsesIndependentSensors() {
    let thresholds = AlertThresholds()
    #expect(ThermalPolicy.instantaneousSeverity(cpu: 79, liquid: 44, thresholds: thresholds) == .normal)
    #expect(ThermalPolicy.instantaneousSeverity(cpu: 81, liquid: 40, thresholds: thresholds) == .warning)
    #expect(ThermalPolicy.instantaneousSeverity(cpu: nil, liquid: 51, thresholds: thresholds) == .critical)
}

@Test
func criticalRecoveryUsesHysteresis() {
    let thresholds = AlertThresholds()
    #expect(!ThermalPolicy.isRecovered(cpu: 89, liquid: 46, from: .critical, thresholds: thresholds))
    #expect(ThermalPolicy.isRecovered(cpu: 86, liquid: 46, from: .critical, thresholds: thresholds))
}

@Test
func smcReadingIsPlausibleWhenAvailable() {
    guard let value = SMCReader()?.cpuTemperature() else { return }
    #expect((0...110).contains(value))
}

@Test @MainActor
func historyRangeAndDownsampling() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LiquidBarTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = HistoryStore(baseDirectory: directory)
    let snapshot = DeviceSnapshot(
        liquidTemperature: 40,
        pumpRPM: 2_000,
        pumpDuty: 70,
        fanRPM: [800, 700, 600],
        fanDuty: [50, 50, 50],
        connected: true
    )
    for _ in 0..<20 { store.append(cpuTemperature: 55, snapshot: snapshot) }
    #expect(store.samples(in: .oneDay, maximumPoints: 5).count <= 7)
}
