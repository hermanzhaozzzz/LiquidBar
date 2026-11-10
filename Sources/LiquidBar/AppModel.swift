import AppKit
import Combine
import Foundation
import FanControlShared
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = DeviceSnapshot.unavailable
    @Published private(set) var cpuTemperature: Double?
    @Published private(set) var cpuPower: Double?
    @Published private(set) var cpuUtilization: Double?
    @Published private(set) var gpuSnapshot = GPUSnapshot.unavailable
    @Published private(set) var displayError: String?
    @Published private(set) var displayLastSent: Date?
    @Published private(set) var motherboardSnapshot: MotherboardFanSnapshot?
    @Published private(set) var motherboardError: String?
    @Published private(set) var motherboardTestResult: String?
    @Published private(set) var fanServiceStatus: FanControlStatus?
    @Published var motherboardCPUTarget = 50.0
    @Published var motherboardPumpTarget = 100.0
    @Published private(set) var severity: AlertSeverity = .normal
    @Published private(set) var lastError: String?
    @Published private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    @Published var fanTargets = [50.0, 50.0, 50.0]
    @Published var pumpTarget = 70.0
    @Published var selectedRange: ChartRange = .fifteenMinutes
    @Published var popoverOpen = false
    @Published var busy = false
    @Published var motherboardBusy = false

    let settingsStore: SettingsStore
    let historyStore: HistoryStore
    lazy var notifications = NotificationManager()

    private let liquidctl: LiquidctlService
    private let smc = SMCReader()
    private let motherboard: MotherboardService
    private let privilegedFans = PrivilegedFanService()
    private let fanServiceInstalled: () -> Bool
    // CPU telemetry never shares the actor/process that may await fan-control authorization.
    private let cpuTelemetry = MotherboardService()
    private let cpuLoad = SystemCPULoad()
    private let gpuReader = GPUReader()
    private var commandError: String?
    private var lastCurveDuty: Int?
    private var lastCurveWrite = Date.distantPast
    private var motherboardInitialized = false
    private var persistentSessionPrepared = false
    private var motherboardReadAt: Date?
    private var suspended = false
    private var cpuTask: Task<Void, Never>?
    private var gpuTask: Task<Void, Never>?
    private var powerTask: Task<Void, Never>?
    private var motherboardTask: Task<Void, Never>?
    private var cpuReadAt: Date?
    private var powerReadAt: Date?
    private var boardTemperature: Double?
    private var boardPower: Double?
    private var deviceTask: Task<Void, Never>?
    private var failureStartedAt: Date?
    private var didNotifyDeviceFailure = false
    private var candidateSeverity: AlertSeverity = .normal
    private var candidateStartedAt = Date()
    private var recoveryStartedAt: Date?
    private var emergencyRestore: (fans: [Int], pump: Int)?
    private var lastHistoryAt = Date.distantPast
    private var started = false

    init(settingsStore: SettingsStore? = nil, historyStore: HistoryStore? = nil,
         liquidctl: LiquidctlService? = nil, motherboard: MotherboardService? = nil,
         fanServiceInstalled: @escaping () -> Bool = { PrivilegedFanService.isInstalled }) {
        self.liquidctl = liquidctl ?? LiquidctlService()
        self.motherboard = motherboard ?? MotherboardService()
        self.fanServiceInstalled = fanServiceInstalled
        let resolvedSettingsStore = settingsStore ?? SettingsStore()
        let resolvedHistoryStore = historyStore ?? HistoryStore()
        self.settingsStore = resolvedSettingsStore
        self.historyStore = resolvedHistoryStore
        let settings = resolvedSettingsStore.value
        if let presetID = settings.lastPreset, let preset = settings.presets[presetID] {
            fanTargets = Array(repeating: Double(preset.fanDuty), count: 3)
            pumpTarget = Double(preset.pumpDuty)
        } else {
            fanTargets = settings.manualFanDuty.map(Double.init)
            pumpTarget = Double(settings.manualPumpDuty)
        }
    }

    deinit {
        cpuTask?.cancel()
        gpuTask?.cancel()
        powerTask?.cancel()
        motherboardTask?.cancel()
        deviceTask?.cancel()
    }

    var menuBarText: String {
        menuBarItems.map(\.accessibilityText).joined(separator: "  ")
    }

    var menuBarItems: [MenuBarTemperatureItem] {
        Self.menuBarItems(
            cpuTemperature: ThermalPolicy.freshReading(cpuTemperature, sampledAt: cpuReadAt),
            liquidTemperature: Date().timeIntervalSince(snapshot.timestamp) <= 15 ? snapshot.liquidTemperature : nil,
            showLiquidTemperature: settingsStore.value.showLiquidTemperatureInMenuBar == true,
            liquidSensorAvailable: snapshot.hasLiquidSensor,
            gpuTemperature: gpuReading?.temperature,
            temperatureDisplay: settingsStore.value.menuBarTemperatureDisplay ?? .cpu,
            thresholds: settingsStore.value.thresholds
        )
    }

    static func formatMenuBarText(
        cpuTemperature: Double?,
        liquidTemperature: Double?,
        showLiquidTemperature: Bool,
        liquidSensorAvailable: Bool = true,
        gpuTemperature: Double? = nil,
        temperatureDisplay: MenuBarTemperatureDisplay = .cpu
    ) -> String {
        menuBarItems(cpuTemperature: cpuTemperature, liquidTemperature: liquidTemperature,
                     showLiquidTemperature: showLiquidTemperature, liquidSensorAvailable: liquidSensorAvailable,
                     gpuTemperature: gpuTemperature, temperatureDisplay: temperatureDisplay)
            .map(\.accessibilityText).joined(separator: "  ")
    }

    static func menuBarItems(cpuTemperature: Double?, liquidTemperature: Double?,
                             showLiquidTemperature: Bool, liquidSensorAvailable: Bool = true,
                             gpuTemperature: Double? = nil, temperatureDisplay: MenuBarTemperatureDisplay = .cpu,
                             thresholds: AlertThresholds = AlertThresholds()) -> [MenuBarTemperatureItem] {
        var items: [MenuBarTemperatureItem] = []
        if temperatureDisplay != .gpu {
            items.append(MenuBarTemperatureItem(sensor: .cpu, temperature: cpuTemperature, thresholds: thresholds))
        }
        if temperatureDisplay != .cpu {
            items.append(MenuBarTemperatureItem(sensor: .gpu, temperature: gpuTemperature, thresholds: thresholds))
        }
        if showLiquidTemperature && liquidSensorAvailable {
            items.append(MenuBarTemperatureItem(sensor: .liquid, temperature: liquidTemperature, thresholds: thresholds))
        }
        return items
    }

    var chartSamples: [HistorySample] {
        historyStore.samples(in: selectedRange)
    }

    var gpuReading: GPUReading? { gpuSnapshot.primaryReading() }

    func start() {
        guard !started else { return }
        started = true
        AppLogger.shared.log("LiquidBar started")
        Task {
            await notifications.refreshAuthorization()
            refreshLoginItemStatus()
            if settingsStore.value.launchAtLogin { configureLaunchAtLogin(enabled: true) }
        }
        startLoops()
        Task {
            await prepareRadiatorControl()
            await refreshDevice()
            await restoreSavedCoolingState()
            await restoreLighting()
        }
    }

    func stop() async -> Bool {
        suspended = true
        cpuTask?.cancel()
        gpuTask?.cancel()
        gpuSnapshot = .unavailable
        powerTask?.cancel()
        motherboardTask?.cancel()
        deviceTask?.cancel()
        var shutdownErrors: [String] = []
        do { try await privilegedFans.shutdown() }
        catch { shutdownErrors.append("CPU fan service restore: \(error.localizedDescription)") }
        do { try await motherboard.restoreAllOverrides() }
        catch { shutdownErrors.append("Motherboard restore: \(error.localizedDescription)") }
        do { try await motherboard.shutdown() }
        catch { shutdownErrors.append("Motherboard shutdown: \(error.localizedDescription)") }
        do { try await cpuTelemetry.shutdown() }
        catch { AppLogger.shared.log("CPU telemetry shutdown: \(error.localizedDescription)") }
        historyStore.flush()
        do { try await liquidctl.stop() }
        catch { shutdownErrors.append("USB shutdown: \(error.localizedDescription)") }
        if !shutdownErrors.isEmpty {
            commandError = shutdownErrors.joined(separator: "\n")
            lastError = commandError
            AppLogger.shared.log("Safety shutdown unconfirmed: \(commandError!)")
            snapshot = .unavailable
            motherboardSnapshot = nil
            boardPower = nil
            boardTemperature = nil
            powerReadAt = nil
            cpuTemperature = nil
            cpuPower = nil
            cpuUtilization = nil
            cpuReadAt = nil
            startCPULoop(allowWhileSuspended: true)
            return false
        }
        AppLogger.shared.log("LiquidBar stopped")
        return true
    }

    func handleSleep() async {
        suspended = true
        gpuSnapshot = .unavailable
        do { try await privilegedFans.shutdown() }
        catch { motherboardError = error.localizedDescription }
        do { try await motherboard.restoreAllOverrides() }
        catch { motherboardError = error.localizedDescription }
        do { try await liquidctl.stop() }
        catch { commandError = error.localizedDescription; lastError = commandError }
    }

    func setPopoverOpen(_ open: Bool) {
        popoverOpen = open
    }

    func refreshNow() {
        Task { await refreshDevice() }
        Task { await prepareRadiatorControl() }
        refreshCPU()
        Task { await refreshGPU() }
    }

    func handleWake() {
        suspended = false
        lastCurveDuty = nil
        Task {
            busy = true
            defer { busy = false }
            do {
                try await liquidctl.reconnect()
                await refreshDevice()
                await restoreSavedCoolingState()
                await restoreLighting()
                await prepareRadiatorControl()
            } catch {
                lastError = error.localizedDescription
                AppLogger.shared.log("wake recovery failed: \(error.localizedDescription)")
            }
        }
    }

    func applyFan(index: Int) {
        guard fanTargets.indices.contains(index), snapshot.hasSmart, !busy else { return }
        disableCurve()
        if settingsStore.value.linkedFans {
            fanTargets = Array(repeating: fanTargets[index], count: 3)
            applyManualState()
            return
        }
        let duty = Int(fanTargets[index].rounded())
        fanTargets[index] = Double(min(100, max(30, duty)))
        settingsStore.value.lastPreset = nil
        settingsStore.value.manualFanDuty = fanTargets.map { Int($0.rounded()) }
        Task { await performWrite { try await self.liquidctl.setFan(index: index + 1, duty: duty) } }
    }

    func applyPump() {
        guard snapshot.hasPump, !busy else { return }
        let duty = min(100, max(50, Int(pumpTarget.rounded())))
        pumpTarget = Double(duty)
        settingsStore.value.lastPreset = nil
        settingsStore.value.manualPumpDuty = duty
        Task { await performWrite { try await self.liquidctl.setPump(duty: duty) } }
    }

    func applyPreset(_ id: PresetID) {
        guard let preset = settingsStore.value.presets[id], !busy else { return }
        disableCurve()
        fanTargets = Array(repeating: Double(preset.fanDuty), count: 3)
        pumpTarget = Double(preset.pumpDuty)
        settingsStore.value.lastPreset = id
        settingsStore.value.manualFanDuty = Array(repeating: preset.fanDuty, count: 3)
        settingsStore.value.manualPumpDuty = preset.pumpDuty
        Task {
            await performWrite {
                try await self.liquidctl.apply(
                    fans: self.snapshot.hasSmart ? Array(repeating: preset.fanDuty, count: 3) : nil,
                    pump: self.snapshot.hasPump ? preset.pumpDuty : nil
                )
            }
        }
    }

    func identifyFan(_ index: Int) {
        guard snapshot.hasSmart, !busy else { return }
        Task { await performWrite { try await self.liquidctl.identifyFan(index: index + 1) } }
    }

    func updateNotifications(enabled: Bool) {
        settingsStore.value.notificationsEnabled = enabled
        guard enabled else { return }
        Task {
            if notifications.authorizationStatus == .notDetermined {
                let granted = await notifications.requestAuthorization()
                if !granted { settingsStore.value.notificationsEnabled = false }
            } else {
                await notifications.refreshAuthorization()
                if notifications.authorizationStatus != .authorized {
                    settingsStore.value.notificationsEnabled = false
                }
            }
        }
    }

    func refreshNotificationAuthorization() {
        Task { await notifications.refreshAuthorization() }
    }

    func updateLaunchAtLogin(enabled: Bool) {
        settingsStore.value.launchAtLogin = enabled
        configureLaunchAtLogin(enabled: enabled)
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func copyDiagnostics() {
        let report = """
        LiquidBar \(AppVersion.current)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        CPU: \(cpuTemperature.map { String(format: "%.1f °C", $0) } ?? "unavailable")
        GPU: \(gpuReading?.name ?? "unavailable")
        GPU temperature: \(gpuReading?.temperature.map { String(format: "%.1f °C", $0) } ?? "unavailable")
        GPU fan: \(gpuReading?.fanRPM.map(String.init) ?? "--") rpm (monitoring only)
        Liquid: \(snapshot.liquidTemperature.map { String(format: "%.1f °C", $0) } ?? "unavailable")
        Fans: \(snapshot.fanRPM.map { $0.map(String.init) ?? "--" }.joined(separator: ", ")) rpm
        Pump: \(snapshot.pumpRPM.map(String.init) ?? "--") rpm
        Noise: \(snapshot.noiseLevel.map(String.init) ?? "--") dB
        Connected: \(snapshot.connected)
        Last error: \(lastError ?? "none")

        Recent log:
        \(AppLogger.shared.contents())
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    func clearLog() {
        AppLogger.shared.clear()
    }

    private func startLoops() {
        startCPULoop()
        gpuTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshGPU()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        startDeviceLoops()
    }

    private func refreshGPU() async {
        guard !suspended else { return }
        let reading = await gpuReader.read()
        guard !suspended, !Task.isCancelled else { return }
        gpuSnapshot = reading
    }

    private func startCPULoop(allowWhileSuspended: Bool = false) {
        cpuTask?.cancel()
        cpuTask = Task { [weak self] in
            while !Task.isCancelled {
                if self?.suspended == false || allowWhileSuspended { self?.refreshCPU() }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func startDeviceLoops() {
        powerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.suspended {
                    do {
                        let metrics = try await self.cpuTelemetry.cpuMetrics()
                        self.boardPower = metrics.powerWatts
                        self.boardTemperature = metrics.temperature
                        self.powerReadAt = Date()
                    } catch {
                        self.boardPower = nil
                        self.boardTemperature = nil
                        self.powerReadAt = nil
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        motherboardTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.suspended && !self.motherboardBusy {
                    if !self.usesTemporaryMotherboardControl && self.persistentFanServiceInstalled {
                        await self.prepareRadiatorControl()
                    } else if self.motherboardInitialized {
                        await self.refreshMotherboard()
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        deviceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.suspended {
                    await self.refreshDevice()
                    await self.updateAutomaticControls()
                }
                let seconds: UInt64 = self.popoverOpen ? 2 : 5
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    private func refreshCPU() {
        // Never await motherboard control here: its authorization dialog may remain
        // open while independent SMC monitoring and thermal protection must continue.
        cpuTemperature = smc?.cpuTemperature() ?? ThermalPolicy.freshReading(boardTemperature, sampledAt: powerReadAt)
        cpuReadAt = cpuTemperature == nil ? nil : Date()
        cpuPower = ThermalPolicy.freshReading(boardPower, sampledAt: powerReadAt)
        cpuUtilization = cpuLoad.sample()
        if Date().timeIntervalSince(lastHistoryAt) >= 5 {
            let recent = Date().timeIntervalSince(snapshot.timestamp) < 15 ? snapshot : .unavailable
            historyStore.append(cpuTemperature: cpuTemperature, snapshot: recent, gpu: gpuReading)
            lastHistoryAt = Date()
        }
        if !suspended { evaluateThermalState() }
    }

    private func refreshDevice() async {
        do {
            let newSnapshot = try await liquidctl.status()
            snapshot = newSnapshot
            updateErrorSummary()
            failureStartedAt = nil
            didNotifyDeviceFailure = false
            evaluateThermalState()
        } catch {
            snapshot = .unavailable
            lastError = error.localizedDescription
            AppLogger.shared.log("device read failed: \(error.localizedDescription)")
            if failureStartedAt == nil { failureStartedAt = Date() }
            if let failureStartedAt,
               Date().timeIntervalSince(failureStartedAt) >= 60,
               !didNotifyDeviceFailure {
                didNotifyDeviceFailure = true
                if settingsStore.value.notificationsEnabled {
                    notifications.sendDeviceError()
                }
            }
        }
    }

    private func updateErrorSummary() {
        let summary = snapshot.errors.keys.sorted().map { "\($0): \(snapshot.errors[$0]!)" }.joined(separator: "; ")
        lastError = commandError ?? (summary.isEmpty ? nil : summary)
    }

    private func applyManualState() {
        let fans = fanTargets.map { min(100, max(30, Int($0.rounded()))) }
        let pump = min(100, max(50, Int(pumpTarget.rounded())))
        settingsStore.value.lastPreset = nil
        settingsStore.value.manualFanDuty = fans
        settingsStore.value.manualPumpDuty = pump
        Task { await performWrite { try await self.liquidctl.apply(
            fans: self.snapshot.hasSmart ? fans : nil,
            pump: self.snapshot.hasPump ? pump : nil
        ) } }
    }

    private func restoreSavedCoolingState() async {
        let settings = settingsStore.value
        let fans: [Int]
        let pump: Int
        if let id = settings.lastPreset, let preset = settings.presets[id] {
            fans = Array(repeating: preset.fanDuty, count: 3)
            pump = preset.pumpDuty
        } else {
            fans = settings.manualFanDuty
            pump = settings.manualPumpDuty
        }
        guard snapshot.hasSmart || snapshot.hasPump else { return }
        if settings.fanCurve?.enabled == true { return }
        await performWrite { try await self.liquidctl.apply(
            fans: self.snapshot.hasSmart ? fans : nil,
            pump: self.snapshot.hasPump ? pump : nil
        ) }
    }

    private func performWrite(_ operation: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await operation()
            commandError = nil
            AppLogger.shared.log("device setting applied")
            await refreshDevice()
        } catch {
            commandError = error.localizedDescription
            lastError = commandError
            AppLogger.shared.log("device write failed: \(error.localizedDescription)")
            await refreshDevice()
        }
    }

    private func evaluateThermalState() {
        let thresholds = settingsStore.value.thresholds
        let instant = ThermalPolicy.instantaneousSeverity(
            cpu: cpuTemperature,
            liquid: snapshot.liquidTemperature,
            thresholds: thresholds
        )
        let now = Date()

        if instant > severity {
            if candidateSeverity != instant {
                candidateSeverity = instant
                candidateStartedAt = now
            } else if now.timeIntervalSince(candidateStartedAt) >= thresholds.triggerDelay {
                transition(to: instant)
            }
            recoveryStartedAt = nil
            return
        }

        candidateSeverity = instant
        candidateStartedAt = now
        guard severity != .normal,
              ThermalPolicy.isRecovered(
                cpu: cpuTemperature,
                liquid: snapshot.liquidTemperature,
                from: severity,
                thresholds: thresholds
              ) else {
            recoveryStartedAt = nil
            return
        }

        if recoveryStartedAt == nil { recoveryStartedAt = now }
        let required = emergencyRestore == nil ? thresholds.triggerDelay : thresholds.recoveryDelay
        if let recoveryStartedAt, now.timeIntervalSince(recoveryStartedAt) >= required {
            transition(to: instant)
            self.recoveryStartedAt = nil
        }
    }

    private func transition(to newSeverity: AlertSeverity) {
        let old = severity
        severity = newSeverity
        guard newSeverity != old else { return }
        AppLogger.shared.log("thermal severity changed from \(old.rawValue) to \(newSeverity.rawValue)")

        if newSeverity > old,
           settingsStore.value.notificationsEnabled {
            notifications.send(
                severity: newSeverity,
                soundEnabled: settingsStore.value.criticalSoundEnabled
            )
        }

        if newSeverity == .critical,
           settingsStore.value.automaticEmergencyBoost,
           emergencyRestore == nil {
            emergencyRestore = (
                fans: fanTargets.map { Int($0.rounded()) },
                pump: Int(pumpTarget.rounded())
            )
            Task { await performWrite { try await self.liquidctl.apply(
                fans: self.snapshot.hasSmart ? [100, 100, 100] : nil,
                pump: self.snapshot.hasPump ? 100 : nil
            ) } }
        } else if newSeverity == .normal, let restore = emergencyRestore {
            emergencyRestore = nil
            fanTargets = restore.fans.map(Double.init)
            pumpTarget = Double(restore.pump)
            Task { await performWrite { try await self.liquidctl.apply(
                fans: self.snapshot.hasSmart ? restore.fans : nil,
                pump: self.snapshot.hasPump ? restore.pump : nil
            ) } }
        }
    }

    func setCurveEnabled(_ enabled: Bool) {
        var curve = settingsStore.value.fanCurve ?? FanCurveSettings()
        curve.enabled = enabled
        settingsStore.value.fanCurve = curve
        lastCurveDuty = nil
        if enabled { settingsStore.value.lastPreset = nil }
        Task {
            if enabled {
                await updateAutomaticControls()
            } else {
                await performWrite { try await self.liquidctl.disarmCurve() }
            }
        }
    }

    private func disableCurve() {
        if settingsStore.value.fanCurve?.enabled == true {
            settingsStore.value.fanCurve?.enabled = false
        }
        lastCurveDuty = nil
    }

    private func updateAutomaticControls() async {
        guard !busy, !suspended else { return }
        if let curve = settingsStore.value.fanCurve, curve.enabled, snapshot.hasSmart {
            let duty = severity == .critical ? 100 : curve.duty(for: ThermalPolicy.freshReading(cpuTemperature, sampledAt: cpuReadAt))
            // Each successful update renews the helper's 15-second safety lease.
            // Device polling runs every 2–5 seconds, even at a constant target.
            if lastCurveDuty == nil || abs(duty - (lastCurveDuty ?? duty)) >= 2 ||
                Date().timeIntervalSince(lastCurveWrite) >= 4 {
                do {
                    try await liquidctl.apply(fans: [duty, duty, duty], pump: nil, curve: true)
                    fanTargets = Array(repeating: Double(duty), count: 3)
                    lastCurveDuty = duty
                    lastCurveWrite = Date()
                } catch {
                    commandError = error.localizedDescription
                    updateErrorSummary()
                }
            }
        }
        if settingsStore.value.display?.enabled == true { await sendDisplay() }
    }

    func applyLighting(_ device: String, settings: LightingSettings) {
        guard snapshot.supports(device, "lighting"), !busy else { return }
        Task {
            await performWrite {
                try await self.liquidctl.setLighting(device: device, settings: settings)
                self.settingsStore.value.lighting = (self.settingsStore.value.lighting ?? [:]).merging(
                    [device: settings], uniquingKeysWith: { _, new in new }
                )
            }
        }
    }

    private func restoreLighting() async {
        for (device, settings) in settingsStore.value.lighting ?? [:] {
            guard snapshot.supports(device, "lighting") else { continue }
            do { try await liquidctl.setLighting(device: device, settings: settings) }
            catch { commandError = error.localizedDescription; updateErrorSummary() }
        }
    }

    func setDisplayEnabled(_ enabled: Bool) {
        var display = settingsStore.value.display ?? DisplaySettings()
        display.enabled = enabled
        settingsStore.value.display = display
        Task {
            if enabled { await sendDisplay() }
            else {
                do { try await liquidctl.updateDisplay(enabled: false, temperature: nil, utilization: nil, power: nil, unit: display.unit) }
                catch { displayError = error.localizedDescription }
                displayLastSent = nil
            }
        }
    }

    private func sendDisplay() async {
        guard snapshot.supports("ld", "display") else {
            displayError = L10n.text("displayDisconnected")
            return
        }
        do {
            try await liquidctl.updateDisplay(
                enabled: true, temperature: ThermalPolicy.freshReading(cpuTemperature, sampledAt: cpuReadAt),
                utilization: ThermalPolicy.freshReading(cpuUtilization, sampledAt: cpuReadAt),
                power: ThermalPolicy.freshReading(boardPower, sampledAt: powerReadAt), unit: settingsStore.value.display?.unit ?? "C"
            )
            displayLastSent = Date()
            displayError = nil
        } catch { displayError = error.localizedDescription }
    }

    var radiatorMappingConfirmed: Bool {
        if !usesTemporaryMotherboardControl { return persistentFanServiceInstalled }
        return settingsStore.value.motherboardMapping?.confirmedIndex(for: .cpu) != nil
    }

    var persistentFanServiceInstalled: Bool { fanServiceInstalled() }
    var usesTemporaryMotherboardControl: Bool {
        settingsStore.value.temporaryMotherboardControl == true && !persistentFanServiceInstalled
    }

    var showRadiatorControl: Bool {
        persistentFanServiceInstalled || settingsStore.value.motherboardMapping?.cpuIndex != nil
    }

    var radiatorControlReason: String? {
        Self.radiatorControlReason(for: fanServiceStatus)
    }

    static func radiatorControlReason(for status: FanControlStatus?) -> String? {
        // A recovery label is a claim about readback, not just the attempted action.
        guard let status, status.automatic, status.error == nil else { return nil }
        let reason = status.lastReason
        let keys = ["startup": "fanReasonStartup", "client_disconnected": "fanReasonDisconnected",
                    "lease_timeout": "fanReasonTimeout", "overheat": "fanReasonHot", "sleep": "fanReasonSleep", "wake": "fanReasonWake",
                    "automatic_control_recovered": "fanReasonRecovered",
                    "invalid_temperature": "fanReasonTelemetry", "invalid_or_hot_temperature": "fanReasonTelemetry",
                    "telemetry_failed": "fanReasonTelemetry", "fan_feedback_missing": "fanReasonTelemetry",
                    "external_automatic_control": "fanReasonExternal", "write_failed": "fanReasonWrite"]
        return keys[reason].map(L10n.text)
    }

    func setTemporaryMotherboardControl(_ enabled: Bool) async {
        guard !motherboardBusy, !persistentFanServiceInstalled else { return }
        if !enabled {
            do {
                try await motherboard.restoreAllOverrides()
                try await motherboard.shutdown()
                motherboardInitialized = false; motherboardSnapshot = nil; motherboardReadAt = nil
            } catch { motherboardError = error.localizedDescription; return }
        }
        settingsStore.value.temporaryMotherboardControl = enabled
        motherboardError = nil
        if enabled { await prepareRadiatorControl() }
    }

    var radiatorFan: MotherboardFanReading? {
        if !usesTemporaryMotherboardControl {
            guard let value = fanServiceStatus, Date().timeIntervalSince(value.sampledAt) <= 6 else { return nil }
            return MotherboardFanReading(index: value.cpuIndex, name: "CPU_FAN", rpm: value.rpm,
                                         duty: value.duty, automatic: value.automatic,
                                         rawDuty: UInt8(clamping: Int((Double(value.duty) * 255 / 100).rounded())))
        }
        guard let index = settingsStore.value.motherboardMapping?.cpuIndex,
              let motherboardReadAt, Date().timeIntervalSince(motherboardReadAt) <= 6 else { return nil }
        return motherboardSnapshot?.fans.first { $0.index == index }
    }

    var canControlRadiator: Bool {
        radiatorMappingConfirmed && radiatorFan != nil && (usesTemporaryMotherboardControl ? motherboardInitialized : true) && !motherboardBusy && !suspended
    }

    // Monitoring a verified header never restores or applies a saved duty.
    // BIOS keeps control after startup until the user moves the slider.
    private func retireTemporaryMotherboardSession() async throws {
        guard !persistentSessionPrepared else { return }
        // An old session's watchdog must not restore after the daemon takes over.
        try await motherboard.restoreAllOverrides()
        try await motherboard.shutdown()
        motherboardInitialized = false; motherboardSnapshot = nil; motherboardReadAt = nil
        persistentSessionPrepared = true
    }

    func prepareRadiatorControl() async {
        if !usesTemporaryMotherboardControl {
            guard !motherboardBusy, !suspended else { return }
            do {
                try await retireTemporaryMotherboardSession()
                let wasUnavailable = fanServiceStatus == nil
                let status = try await privilegedFans.status()
                fanServiceStatus = status
                motherboardError = status.error
                if wasUnavailable { motherboardCPUTarget = Double(status.duty) }
            } catch {
                fanServiceStatus = nil
                motherboardError = error.localizedDescription
            }
            return
        }
        guard radiatorMappingConfirmed, !motherboardBusy, !suspended else { return }
        if motherboardInitialized { await refreshMotherboard() }
        else { await detectMotherboard() }
    }

    func initializeMotherboard() {
        Task {
            if usesTemporaryMotherboardControl { await detectMotherboard() }
            else { await prepareRadiatorControl() }
        }
    }

    private func detectMotherboard() async {
        guard !motherboardBusy else { return }
        motherboardBusy = true
        persistentSessionPrepared = false
        defer { motherboardBusy = false }
        do {
            recordMotherboard(try await motherboard.initializeFans())
            motherboardInitialized = true
            motherboardError = nil
            if let reading = radiatorFan { motherboardCPUTarget = Double(reading.duty) }
        } catch {
            motherboardSnapshot = nil
            motherboardReadAt = nil
            motherboardInitialized = false
            motherboardError = error.localizedDescription
        }
    }

    private func refreshMotherboard() async {
        do { recordMotherboard(try await motherboard.readFans()) }
        catch {
            motherboardSnapshot = nil
            motherboardReadAt = nil
            motherboardInitialized = false
            motherboardError = error.localizedDescription
        }
    }

    private func recordMotherboard(_ snapshot: MotherboardFanSnapshot) {
        motherboardSnapshot = snapshot
        motherboardReadAt = Date()
    }

    func confirmRadiatorMapping(_ confirmed: Bool) {
        guard var mapping = settingsStore.value.motherboardMapping,
              let index = mapping.cpuIndex, index != mapping.pumpIndex,
              motherboardSnapshot?.fans.contains(where: { $0.index == index }) == true else { return }
        mapping.confirmedCPUIndex = confirmed ? index : nil
        if !confirmed { mapping.confirmed = false }
        settingsStore.value.motherboardMapping = mapping
    }

    func applyMotherboard(_ role: MotherboardFanRole) async {
        if !usesTemporaryMotherboardControl {
            guard role == .cpu, !motherboardBusy, !suspended, motherboardCPUTarget.isFinite,
                  (30...100).contains(motherboardCPUTarget) else { return }
            motherboardBusy = true
            defer { motherboardBusy = false }
            do {
                try await retireTemporaryMotherboardSession()
                let status = try await privilegedFans.setCPU(percent: Int(motherboardCPUTarget.rounded()))
                fanServiceStatus = status
                motherboardError = status.error
            } catch {
                fanServiceStatus = nil
                motherboardError = error.localizedDescription
            }
            return
        }
        guard let index = settingsStore.value.motherboardMapping?.confirmedIndex(for: role),
              motherboardInitialized, !motherboardBusy else { return }
        let target = role == .cpu ? motherboardCPUTarget : motherboardPumpTarget
        guard !suspended, target.isFinite, (Double(role.minimumDuty)...100).contains(target),
              motherboardSnapshot?.fans.contains(where: { $0.index == index }) == true else { return }
        let percent = Int(target.rounded())
        motherboardBusy = true
        defer { motherboardBusy = false }
        do {
            let result = try await motherboard.setDuty(index: index, percent: percent, role: role)
            recordMotherboard(result)
            guard let reading = result.fans.first(where: { $0.index == index }),
                  !reading.automatic, abs(reading.duty - percent) <= 1 else {
                motherboardError = L10n.text("motherboardWriteUnconfirmed")
                return
            }
            motherboardError = nil
        } catch {
            motherboardSnapshot = nil
            motherboardReadAt = nil
            motherboardInitialized = false
            motherboardError = error.localizedDescription
        }
    }

    func restoreRadiatorAutomatic() async {
        if !usesTemporaryMotherboardControl {
            guard !motherboardBusy else { return }
            motherboardBusy = true
            defer { motherboardBusy = false }
            do {
                try await retireTemporaryMotherboardSession()
                let status = try await privilegedFans.restoreCPU()
                fanServiceStatus = status
                motherboardCPUTarget = Double(status.duty)
                motherboardError = status.error
            } catch {
                fanServiceStatus = nil
                motherboardError = error.localizedDescription
            }
            return
        }
        guard let index = settingsStore.value.motherboardMapping?.confirmedIndex(for: .cpu),
              motherboardInitialized, !motherboardBusy else { return }
        motherboardBusy = true
        defer { motherboardBusy = false }
        do {
            let result = try await motherboard.restoreAutomatic(index: index)
            recordMotherboard(result)
            guard let reading = result.fans.first(where: { $0.index == index }), reading.automatic else {
                motherboardError = L10n.text("motherboardRestoreUnconfirmed")
                return
            }
            motherboardCPUTarget = Double(reading.duty)
            motherboardError = nil
        } catch {
            motherboardSnapshot = nil
            motherboardReadAt = nil
            motherboardInitialized = false
            motherboardError = error.localizedDescription
        }
    }

    func testMotherboard(_ role: MotherboardFanRole) {
        guard usesTemporaryMotherboardControl, motherboardInitialized, !motherboardBusy else { return }
        let mapping = settingsStore.value.motherboardMapping
        guard let index = role == .cpu ? mapping?.cpuIndex : mapping?.pumpIndex else { return }
        Task {
            motherboardBusy = true
            defer { motherboardBusy = false }
            do {
                let result = try await motherboard.testIncrease(index: index, role: role)
                motherboardTestResult = "#\(index): \(result.before.rpm) → \(result.during.rpm) → \(result.after.rpm) RPM"
                motherboardError = nil
                await refreshMotherboard()
            } catch { motherboardError = error.localizedDescription }
        }
    }

    func restoreMotherboard() {
        Task {
            do {
                try await motherboard.restoreAllOverrides()
                await refreshMotherboard()
                motherboardError = nil
            } catch { motherboardError = error.localizedDescription }
        }
    }

    private func configureLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .notRegistered ||
                    SMAppService.mainApp.status == .notFound {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled ||
                        SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLogger.shared.log("login item update failed: \(error.localizedDescription)")
        }
        refreshLoginItemStatus()
    }

    private func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
    }
}
