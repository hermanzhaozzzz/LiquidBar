import Foundation
import Testing
@testable import LiquidBar

@Test
func defaultPresetsAndSafetyLimits() {
    var settings = AppSettings()
    #expect(settings.showLiquidTemperatureInMenuBar == false)
    #expect(settings.menuBarTemperatureDisplay == .cpu)
    #expect(settings.presets[.quiet] == CoolingPreset(fanDuty: 35, pumpDuty: 60, radiatorDuty: 40))
    #expect(settings.presets[.daily] == CoolingPreset(fanDuty: 50, pumpDuty: 70, radiatorDuty: 55))
    #expect(settings.presets[.performance] == CoolingPreset(fanDuty: 75, pumpDuty: 90, radiatorDuty: 80))
    #expect(settings.presets[.full] == CoolingPreset(fanDuty: 100, pumpDuty: 100, radiatorDuty: 100))

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
    object.removeValue(forKey: "menuBarTemperatureDisplay")

    var decoded = try JSONDecoder().decode(
        AppSettings.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    decoded.sanitize()

    #expect(decoded.showLiquidTemperatureInMenuBar == false)
    #expect(decoded.menuBarTemperatureDisplay == .cpu)
    #expect(decoded.presets[.performance] == CoolingPreset(fanDuty: 75, pumpDuty: 90, radiatorDuty: 80))
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

@Test
func legacySettingsPreservePreferencesAcrossNewControls() throws {
    var original = AppSettings()
    original.manualFanDuty = [43, 52, 61]
    original.lastPreset = nil
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    for key in ["fanCurve", "lighting", "display", "motherboardMapping"] { json.removeValue(forKey: key) }
    var decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
    decoded.sanitize()
    #expect(decoded.manualFanDuty == [43, 52, 61])
    #expect(decoded.fanCurve?.enabled != true)
    #expect(decoded.display?.enabled != true)
    #expect(decoded.motherboardMapping?.confirmed != true)
}

@Test
func fanCurveInterpolatesAndFailsToFullSpeed() {
    let curve = FanCurveSettings(enabled: true, coolTemperature: 40, hotTemperature: 80, minimumDuty: 40, maximumDuty: 100)
    #expect(curve.duty(for: 30) == 40)
    #expect(curve.duty(for: 60) == 70)
    #expect(curve.duty(for: 85) == 100)
    #expect(curve.duty(for: nil) == 100)
    #expect(curve.duty(for: .nan) == 100)
    var invalid = FanCurveSettings(enabled: true, coolTemperature: 80, hotTemperature: 30, minimumDuty: 90, maximumDuty: 40)
    invalid.sanitize()
    #expect(invalid.hotTemperature > invalid.coolTemperature)
    #expect(invalid.maximumDuty >= invalid.minimumDuty)
}

@Test
func smartOnlyCapabilitiesDoNotInventKrakenTelemetry() throws {
    let data = Data(#"{"devices":{"smart":{"connected":true,"capabilities":["fan_control","fan_rpm","lighting"],"channels":["fan1","fan2","fan3"]},"kraken":{"connected":false,"capabilities":[],"channels":[]}},"fan_rpm":[900,1000,0],"fan_duty":[50,50,50],"errors":{}}"#.utf8)
    let result = try JSONDecoder().decode(HelperData.self, from: data)
    #expect(result.liquidTemperature == nil)
    #expect(result.pumpRPM == nil)
    let snapshot = DeviceSnapshot(connected: true, devices: result.devices ?? [:])
    #expect(snapshot.hasSmart)
    #expect(!snapshot.hasPump)
}

@Test
func applyAcknowledgementsDoNotBreakStatusDecoder() throws {
    let data = Data(#"{"applied":true,"devices":{"smart":true},"errors":{}}"#.utf8)
    let result = try JSONDecoder().decode(HelperData.self, from: data)
    #expect(result.applied == true)
    #expect(result.devices == nil)
}

@Test @MainActor
func historyRecordsCPUWhenUSBIsUnavailable() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = HistoryStore(baseDirectory: directory)
    store.append(cpuTemperature: 61, snapshot: .unavailable)
    #expect(store.samples.last?.cpuTemperature == 61)
    #expect(store.samples.last?.liquidTemperature == nil)
}

private func fakeHelper(_ firstFailure: String) throws -> (URL, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiquidBarIPC-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let helper = directory.appendingPathComponent("helper.py")
    let source = """
    import sys,json,time,pathlib
    root=pathlib.Path(__file__).parent
    marker=root/'started'
    first=not marker.exists()
    marker.write_text('started')
    for line in sys.stdin:
        request=json.loads(line)
        with (root/'requests').open('a') as f: f.write(request['action']+'\\n')
        if first:
            \(firstFailure)
        print(json.dumps({'id':request['id'],'ok':True,'data':{'devices':{'smart':{'connected':True,'capabilities':['fan_control'],'channels':['fan1','fan2','fan3']}},'fan_rpm':[900,800,700],'fan_duty':[50,50,50]}}),flush=True)
    """
    try source.write(to: helper, atomically: true, encoding: .utf8)
    return (directory, helper)
}

@Test
func wrongRequestIDResetsSessionWithoutReplayingWrite() async throws {
    let (directory, helper) = try fakeHelper("print(json.dumps({'id':-1,'ok':True}),flush=True); time.sleep(5)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = LiquidctlService(executable: URL(fileURLWithPath: "/usr/bin/python3"), helper: helper)
    do {
        try await service.setFan(index: 1, duty: 50)
        Issue.record("Wrong response id must fail the write")
    } catch {}
    let status = try await service.status()
    #expect(status.hasSmart)
    try await service.stop()
    let actions = try String(contentsOf: directory.appendingPathComponent("requests"), encoding: .utf8)
    #expect(actions.split(separator: "\n").map(String.init) == ["set", "status"])
}

@Test
func timeoutDiscardsLateResponseBeforeNextRequest() async throws {
    let (directory, helper) = try fakeHelper("time.sleep(8)")
    defer { try? FileManager.default.removeItem(at: directory) }
    // The request after the timeout spawns a fresh Python helper, so the timeout
    // must also cover interpreter startup on a loaded CI runner.
    let service = LiquidctlService(executable: URL(fileURLWithPath: "/usr/bin/python3"), helper: helper, timeout: 3)
    do {
        _ = try await service.status()
        Issue.record("Delayed response must time out")
    } catch {}
    let status = try await service.status()
    #expect(status.fanRPM == [900, 800, 700])
    try await service.stop()
}

@Test
func staleTelemetryCannotHoldLowFanDutyOrFeedDisplay() {
    let now = Date()
    let stale = ThermalPolicy.freshReading(35, sampledAt: now.addingTimeInterval(-7), now: now)
    #expect(stale == nil)
    #expect(FanCurveSettings().duty(for: stale) == 100)
    #expect(ThermalPolicy.freshReading(55, sampledAt: now.addingTimeInterval(-2), now: now) == 55)
    #expect(ThermalPolicy.freshReading(80, sampledAt: nil, now: now) == nil)
}

@Test
func armedUSBHelperRetirementNeverOverlapsAReplacement() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiquidBarRetire-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let helper = directory.appendingPathComponent("helper.py")
    let source = """
    import sys,json,time,pathlib
    root=pathlib.Path(__file__).parent
    with (root/'starts').open('a') as f: f.write('start\\n')
    armed=False
    for line in sys.stdin:
        req=json.loads(line)
        if req.get('curve'): armed=True
        print(json.dumps({'id':req['id'],'ok':True,'data':{'applied':True,'devices':{'smart':{'connected':True,'capabilities':['fan_control'],'channels':[]}},'fan_rpm':[1,2,3]}}),flush=True)
    if armed:
        time.sleep(6)
        (root/'safe').write_text('full-speed complete')
    """
    try source.write(to: helper, atomically: true, encoding: .utf8)
    let service = LiquidctlService(executable: URL(fileURLWithPath: "/usr/bin/python3"), helper: helper)
    try await service.apply(fans: [40, 50, 60], pump: nil, curve: true)
    do {
        try await service.stop()
        Issue.record("Blocked safety shutdown must remain pending")
    } catch {}
    do {
        _ = try await service.status()
        Issue.record("A new USB session must not overlap the retiring armed worker")
    } catch {}
    let starts = try String(contentsOf: directory.appendingPathComponent("starts"), encoding: .utf8)
    #expect(starts.split(separator: "\n").count == 1)
    try await Task.sleep(nanoseconds: 2_200_000_000)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("safe").path))
    _ = try await service.status()
    try await service.stop()
}

@Test
func failedArmedUSBFallbackBlocksFurtherControlSessions() async throws {
    let (directory, helper) = try fakeHelper("raise SystemExit(2)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = LiquidctlService(executable: URL(fileURLWithPath: "/usr/bin/python3"), helper: helper)
    do {
        try await service.apply(fans: [40, 50, 60], pump: nil, curve: true)
        Issue.record("Unconfirmed armed fallback must fail")
    } catch {
        #expect(error.localizedDescription.contains("full-speed fallback"))
    }
    do {
        _ = try await service.status()
        Issue.record("Failed armed retirement must not start a replacement")
    } catch {
        #expect(error.localizedDescription.contains("full-speed fallback"))
    }
    let actions = try String(contentsOf: directory.appendingPathComponent("requests"), encoding: .utf8)
    #expect(actions.split(separator: "\n").map(String.init) == ["apply"])
}

@Test @MainActor
func failedMotherboardShutdownCancelsQuitAndKeepsIndependentHistoryLive() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiquidBarStop-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let helper = directory.appendingPathComponent("board.py")
    try """
    import sys,json,pathlib
    root=pathlib.Path(__file__).parent
    for line in sys.stdin:
        req=json.loads(line)
        with (root/'actions').open('a') as f: f.write(req['action']+'\\n')
        data={'id':req['id']}
        if req['action']=='cpu': data['cpu']={'temperature':55,'powerWatts':70}
        else: data['error']='injected motherboard restoration failure'
        print(json.dumps(data),flush=True)
    raise SystemExit(2)
    """.write(to: helper, atomically: true, encoding: .utf8)
    let board = MotherboardService(helperExecutable: URL(fileURLWithPath: "/usr/bin/python3"), helperArguments: [helper.path])
    _ = try await board.cpuMetrics()
    let history = HistoryStore(baseDirectory: directory)
    let model = AppModel(settingsStore: SettingsStore(baseDirectory: directory), historyStore: history,
                         motherboard: board, fanServiceInstalled: { false })
    let completed = await model.stop()
    #expect(!completed)
    #expect(model.lastError?.contains("injected motherboard restoration failure") == true)
    #expect(model.cpuPower == nil)
    #expect(!model.snapshot.connected)
    let historyDeadline = Date().addingTimeInterval(10)
    while history.samples.count < 2 && Date() < historyDeadline {
        try await Task.sleep(nanoseconds: 200_000_000)
    }
    #expect(history.samples.count >= 2)
    #expect(history.samples.allSatisfy { $0.liquidTemperature == nil })
    let actions = try String(contentsOf: directory.appendingPathComponent("actions"), encoding: .utf8)
    #expect(actions.split(separator: "\n").map(String.init) == ["cpu", "restoreAll"])
}

@Test
func optionalDeviceVisibilityPreservesIndependentHardware() {
    let smart = DeviceCapability(connected: true, capabilities: ["fan_control", "lighting"], channels: ["fan1", "led1"])
    let aura = DeviceCapability(connected: true, capabilities: ["lighting"], channels: ["led2"])
    let ld = DeviceCapability(connected: true, capabilities: ["display"], channels: ["display"])
    let absentKraken = DeviceCapability(connected: false, capabilities: ["pump_control", "liquid_temperature"], channels: ["pump"])
    var snapshot = DeviceSnapshot(connected: true, devices: ["smart": smart, "aura": aura, "ld": ld, "kraken": absentKraken])
    #expect(snapshot.visibleDeviceRoles == ["smart", "aura", "ld"])
    #expect(!snapshot.hasPump)
    #expect(!snapshot.hasLiquidSensor)
    #expect(snapshot.hasSmart)
    #expect(snapshot.supports("aura", "lighting"))
    #expect(snapshot.supports("ld", "display"))
    snapshot.devices["kraken"]?.connected = true
    #expect(snapshot.visibleDeviceRoles == ["smart", "aura", "ld", "kraken"])
    #expect(snapshot.hasPump)
    #expect(snapshot.hasLiquidSensor)
    snapshot.devices["smart"]?.connected = false
    #expect(!snapshot.hasSmart)
    #expect(snapshot.hasPump)
    #expect(snapshot.visibleDeviceRoles == ["aura", "ld", "kraken"])
}

@Test
func disconnectedOptionalDeviceRetainsOnlyUsefulErrorRow() {
    let unavailable = DeviceCapability(connected: false, capabilities: ["pump_control"], channels: ["pump"], error: "USB read failed")
    let snapshot = DeviceSnapshot(devices: ["kraken": unavailable])
    #expect(snapshot.visibleDeviceRoles == ["kraken"])
    #expect(!snapshot.hasPump)
    #expect(!snapshot.hasLiquidSensor)
    #expect(DeviceSnapshot.unavailable.visibleDeviceRoles.isEmpty)
}

@Test @MainActor
func savedLiquidMenuPreferenceDoesNotDisplayAbsentKraken() {
    let absent = AppModel.formatMenuBarText(cpuTemperature: 55, liquidTemperature: nil, showLiquidTemperature: true, liquidSensorAvailable: false)
    #expect(absent == "CPU 55°")
    let present = AppModel.formatMenuBarText(cpuTemperature: 55, liquidTemperature: 33, showLiquidTemperature: true, liquidSensorAvailable: true)
    #expect(present.contains("33°"))
}
