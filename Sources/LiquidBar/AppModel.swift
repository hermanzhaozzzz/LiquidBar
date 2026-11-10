import AppKit
import Combine
import Foundation
import FanControlShared
import ServiceManagement

enum FanServiceHealth: Equatable {
    case notInstalled
    case installed
    case needsUpdate
    case needsRestart
}

struct PermissionAudit: Equatable {
    var notificationsMissing: Bool
    var loginItemMissing: Bool
    var fanServiceNeedsUpdate: Bool
    var fanServiceNeedsRestart: Bool

    var needsAttention: Bool {
        notificationsMissing || loginItemMissing || fanServiceNeedsUpdate || fanServiceNeedsRestart
    }

    var fingerprint: String {
        let fan = fanServiceNeedsRestart ? 2 : (fanServiceNeedsUpdate ? 1 : 0)
        return [
            "notifications=\(notificationsMissing ? 1 : 0)",
            "login=\(loginItemMissing ? 1 : 0)",
            "fan=\(fan)@\(AppVersion.current)#\(AppVersion.build)",
        ].joined(separator: ";")
    }

    // Only the fan-service component needs its own pane; other shortfalls start at permissions.
    var onboardingStep: Int {
        (fanServiceNeedsUpdate || fanServiceNeedsRestart)
            && !notificationsMissing && !loginItemMissing ? 1 : 2
    }
}

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
    @Published private(set) var fanServiceHealth: FanServiceHealth =
        FanServiceInspector.inspect()
    @Published var motherboardCPUTarget = 50.0
    @Published var motherboardPumpTarget = 100.0
    @Published private(set) var severity: AlertSeverity = .normal
    @Published private(set) var lastError: String?
    @Published private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    @Published var fanTargets = [50.0, 50.0, 50.0]
    @Published var pumpTarget = 70.0
    @Published var pumpAutomatic = false
    @Published private(set) var radiatorAutomaticOverride: Bool?
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
    private var emergencyRestore: (fans: [Int], pump: Int, pumpAutomatic: Bool)?
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
        pumpAutomatic = settings.pumpAutomatic == true
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

    // Runs once per launch: ask only for missing permissions, and re-register a lost
    // login item only when the user still wants it. Never nags for an unchanged shortfall.
    func auditPermissions() async -> PermissionAudit {
        await notifications.refreshAuthorization()
        refreshLoginItemStatus()

        if notifications.authorizationStatus == .notDetermined {
            let granted = await notifications.requestAuthorization()
            settingsStore.value.notificationsEnabled = granted
        }

        if settingsStore.value.launchAtLogin,
           loginItemStatus == .notRegistered || loginItemStatus == .notFound {
            configureLaunchAtLogin(enabled: true)
        }

        if persistentFanServiceInstalled && !usesTemporaryMotherboardControl {
            await prepareRadiatorControl()
        }

        let notificationsMissing = settingsStore.value.notificationsEnabled
            && notifications.authorizationStatus != .authorized
        let loginItemMissing = settingsStore.value.launchAtLogin
            && loginItemStatus != .enabled
        let inspected = FanServiceInspector.inspect()
        return PermissionAudit(
            notificationsMissing: notificationsMissing,
            loginItemMissing: loginItemMissing,
            fanServiceNeedsUpdate: inspected == .needsUpdate,
            fanServiceNeedsRestart: inspected == .needsRestart
        )
    }

    // Used by the --ui-preview development flag so layout work never touches hardware.
    func loadPreviewState() {
        cpuTemperature = 58.4
        cpuPower = 92
        cpuUtilization = 37
        snapshot = DeviceSnapshot(
            timestamp: Date(),
            liquidTemperature: 36.2,
            pumpRPM: 2140,
            pumpDuty: 70,
            fanRPM: [980, 1020, nil],
            fanDuty: [50, 50, nil],
            fanModes: ["manual", "manual", nil],
            noiseLevel: nil,
            connected: true,
            devices: [
                "smart": DeviceCapability(
                    connected: true,
                    capabilities: ["fan_control", "lighting"],
                    channels: ["led1", "led2", "sync"]
                ),
                "aura": DeviceCapability(
                    connected: true,
                    capabilities: ["lighting"],
                    channels: ["sync", "led1", "led2", "led3", "led4"]
                ),
                "kraken": DeviceCapability(
                    connected: true,
                    capabilities: ["pump_control", "liquid_temperature"],
                    channels: []
                ),
            ],
            errors: [:]
        )
        gpuSnapshot = GPUSnapshot(sampledAt: Date(), devices: [
            GPUReading(id: 1, name: "Radeon RX 5700 XT", temperature: 54,
                       fanRPM: 1100, fanPercent: 32, powerWatts: 140),
        ])
        fanTargets = [50, 50, 50]
        pumpAutomatic = true
        fanServiceStatus = FanControlStatus(
            cpuIndex: 1, chipID: 54315, driverVersion: "0.7.2",
            rpm: 1448, duty: 53, automatic: true, temperature: 61.9,
            controlledByThisConnection: false, lastReason: "startup"
        )
        cpuReadAt = Date()
        powerReadAt = Date()
    }

    func stop(ignoringFanService: Bool = false) async -> Bool {
        suspended = true
        cpuTask?.cancel()
        gpuTask?.cancel()
        gpuSnapshot = .unavailable
        powerTask?.cancel()
        motherboardTask?.cancel()
        deviceTask?.cancel()
        var shutdownErrors: [String] = []
        if !ignoringFanService {
            do { try await privilegedFans.shutdown() }
            catch { shutdownErrors.append("CPU fan service restore: \(error.localizedDescription)") }
        }
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
        let wasCurve = settingsStore.value.fanCurve?.enabled == true
        let curveDuties = fanTargets.map { min(100, max(30, Int($0.rounded()))) }
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
        Task {
            // Freeze the current curve output as manual targets instead of the
            // helper's full-speed override, then move only the dragged channel.
            if wasCurve {
                await performWrite {
                    try await self.liquidctl.apply(fans: curveDuties, pump: nil, curve: false)
                }
            }
            await performWrite { try await self.liquidctl.setFan(index: index + 1, duty: duty) }
        }
    }

    func applyPump() {
        guard snapshot.hasPump, !busy else { return }
        let duty = min(100, max(50, Int(pumpTarget.rounded())))
        pumpTarget = Double(duty)
        pumpAutomatic = false
        settingsStore.value.pumpAutomatic = false
        settingsStore.value.lastPreset = nil
        settingsStore.value.manualPumpDuty = duty
        Task { await performWrite { try await self.liquidctl.setPump(duty: duty) } }
    }

    func setPumpAutomatic(_ enabled: Bool) {
        guard snapshot.hasPump, !busy else { return }
        pumpAutomatic = enabled
        settingsStore.value.pumpAutomatic = enabled
        guard enabled else {
            if let duty = snapshot.pumpDuty, (50...100).contains(duty) {
                pumpTarget = Double(duty)
            }
            applyPump()
            return
        }
        Task {
            let ok = await performWrite { try await self.liquidctl.setPumpAutomatic() }
            if !ok {
                pumpAutomatic = false
                settingsStore.value.pumpAutomatic = false
            }
        }
    }

    func applyPreset(_ id: PresetID) {
        guard let preset = settingsStore.value.presets[id], !busy else { return }
        disableCurve()
        fanTargets = Array(repeating: Double(preset.fanDuty), count: 3)
        if let radiator = preset.radiatorDuty {
            motherboardCPUTarget = Double(min(100, max(30, radiator)))
        }
        settingsStore.value.lastPreset = id
        settingsStore.value.manualFanDuty = Array(repeating: preset.fanDuty, count: 3)
        Task {
            if self.snapshot.hasSmart {
                await performWrite {
                    try await self.liquidctl.apply(
                        fans: Array(repeating: preset.fanDuty, count: 3),
                        pump: nil
                    )
                }
            }
            if self.radiatorMappingConfirmed {
                await self.applyMotherboard(.cpu)
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
                let interval = self?.settingsStore.value.samplingProfile?.telemetryInterval ?? 2
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
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
                let interval = self?.settingsStore.value.samplingProfile?.telemetryInterval ?? 2
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
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
                let interval = self.settingsStore.value.samplingProfile?.telemetryInterval ?? 2
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
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
                let interval = self.settingsStore.value.samplingProfile?.telemetryInterval ?? 2
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        deviceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.suspended {
                    await self.refreshDevice()
                    await self.updateAutomaticControls()
                }
                let profile = self.settingsStore.value.samplingProfile ?? .balanced
                let seconds = profile.deviceInterval(popoverOpen: self.popoverOpen)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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
            if pumpAutomatic, let duty = newSnapshot.pumpDuty {
                pumpTarget = Double(duty)
            }
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
        settingsStore.value.lastPreset = nil
        settingsStore.value.manualFanDuty = fans
        Task { await performWrite { try await self.liquidctl.apply(
            fans: self.snapshot.hasSmart ? fans : nil,
            pump: nil
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
        if settings.fanCurve?.enabled != true, snapshot.hasSmart {
            await performWrite { try await self.liquidctl.apply(fans: fans, pump: nil) }
        }
        if snapshot.hasPump {
            if settings.pumpAutomatic == true {
                let ok = await performWrite { try await self.liquidctl.setPumpAutomatic() }
                pumpAutomatic = ok
                if !ok { settingsStore.value.pumpAutomatic = false }
            } else {
                await performWrite { try await self.liquidctl.apply(fans: nil, pump: pump) }
            }
        }
    }

    @discardableResult
    private func performWrite(_ operation: @escaping () async throws -> Void) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            try await operation()
            commandError = nil
            AppLogger.shared.log("device setting applied")
            await refreshDevice()
            return true
        } catch {
            commandError = error.localizedDescription
            lastError = commandError
            AppLogger.shared.log("device write failed: \(error.localizedDescription)")
            await refreshDevice()
            return false
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
                pump: Int(pumpTarget.rounded()),
                pumpAutomatic: pumpAutomatic
            )
            Task { await performWrite { try await self.liquidctl.apply(
                fans: self.snapshot.hasSmart ? [100, 100, 100] : nil,
                pump: self.snapshot.hasPump ? 100 : nil
            ) } }
        } else if newSeverity == .normal, let restore = emergencyRestore {
            emergencyRestore = nil
            fanTargets = restore.fans.map(Double.init)
            pumpTarget = Double(restore.pump)
            Task {
                if self.snapshot.hasSmart {
                    await self.performWrite {
                        try await self.liquidctl.apply(fans: restore.fans, pump: nil)
                    }
                }
                if self.snapshot.hasPump {
                    if restore.pumpAutomatic {
                        let ok = await self.performWrite {
                            try await self.liquidctl.setPumpAutomatic()
                        }
                        self.pumpAutomatic = ok
                        if !ok {
                            self.settingsStore.value.pumpAutomatic = false
                            await self.performWrite {
                                try await self.liquidctl.apply(fans: nil, pump: restore.pump)
                            }
                        }
                    } else {
                        await self.performWrite {
                            try await self.liquidctl.apply(fans: nil, pump: restore.pump)
                        }
                    }
                }
            }
        }
    }

    func setCurveEnabled(_ enabled: Bool) {
        var curve = settingsStore.value.fanCurve ?? FanCurveSettings()
        curve.enabled = enabled
        settingsStore.value.fanCurve = curve
        objectWillChange.send()
        lastCurveDuty = nil
        if enabled { settingsStore.value.lastPreset = nil }
        Task {
            if enabled {
                await updateAutomaticControls()
            } else {
                // Freeze the current curve output as manual targets. Only fall back
                // to the full-speed failsafe if that write cannot be confirmed.
                let duties = (0..<3).map { index in
                    let value = self.snapshot.fanDuty[index]
                        ?? Int(self.fanTargets[index].rounded())
                    return min(100, max(30, value))
                }
                let ok = await performWrite {
                    try await self.liquidctl.apply(fans: duties, pump: nil, curve: false)
                }
                if ok {
                    fanTargets = duties.map(Double.init)
                    settingsStore.value.manualFanDuty = duties
                } else {
                    let safe = await performWrite {
                        try await self.liquidctl.disarmCurve()
                    }
                    if safe {
                        fanTargets = [100, 100, 100]
                        settingsStore.value.manualFanDuty = [100, 100, 100]
                    }
                }
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

    func applyLightingToAll(_ values: [String: LightingSettings]) {
        guard !busy else { return }
        let targets = values.filter { snapshot.supports($0.key, "lighting") }
        guard !targets.isEmpty else { return }
        Task {
            await performWrite {
                for (role, settings) in targets {
                    try await self.liquidctl.setLighting(device: role, settings: settings)
                }
                var lighting = self.settingsStore.value.lighting ?? [:]
                for (role, settings) in targets { lighting[role] = settings }
                self.settingsStore.value.lighting = lighting
            }
        }
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

    static func fanServiceHealth(for error: Error) -> FanServiceHealth {
        _ = error
        return FanServiceInspector.inspect(force: true)
    }

    func completeFanServiceInstall() {
        FanServiceInspector.invalidate()
        fanServiceStatus = nil
        fanServiceHealth = .installed
        motherboardError = nil
    }

    func restartApplication() {
        Task { @MainActor in
            _ = await stop()
            InAppFanServiceInstaller.relaunchAndExit()
        }
    }
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
            switch FanServiceInspector.inspect() {
            case .notInstalled:
                fanServiceStatus = nil
                fanServiceHealth = .notInstalled
                motherboardError = nil
                return
            case .needsUpdate:
                fanServiceStatus = nil
                fanServiceHealth = .needsUpdate
                motherboardError = nil
                return
            case .needsRestart:
                fanServiceStatus = nil
                fanServiceHealth = .needsRestart
                motherboardError = nil
                return
            case .installed:
                break
            }
            do {
                try await retireTemporaryMotherboardSession()
                let wasUnavailable = fanServiceStatus == nil
                let status = try await privilegedFans.status()
                fanServiceStatus = status
                fanServiceHealth = .installed
                motherboardError = status.error
                if status.automatic || wasUnavailable {
                    motherboardCPUTarget = Double(status.duty)
                }
            } catch {
                let inspected = FanServiceInspector.inspect(force: true)
                fanServiceStatus = nil
                fanServiceHealth = inspected
                motherboardError = inspected == .installed ? error.localizedDescription : nil
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
        do {
            let updated = try await motherboard.readFans()
            recordMotherboard(updated)
            if let index = settingsStore.value.motherboardMapping?.confirmedIndex(for: .cpu),
               let reading = updated.fans.first(where: { $0.index == index }),
               reading.automatic {
                motherboardCPUTarget = Double(reading.duty)
            }
        }
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
            radiatorAutomaticOverride = false
            defer { motherboardBusy = false }
            do {
                try await retireTemporaryMotherboardSession()
                let status = try await privilegedFans.setCPU(percent: Int(motherboardCPUTarget.rounded()))
                fanServiceStatus = status
                fanServiceHealth = .installed
                motherboardError = status.error
                radiatorAutomaticOverride = nil
            } catch {
                fanServiceStatus = nil
                motherboardError = error.localizedDescription
                fanServiceHealth = Self.fanServiceHealth(for: error)
                radiatorAutomaticOverride = nil
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
        if role == .cpu { radiatorAutomaticOverride = false }
        defer { motherboardBusy = false }
        do {
            let result = try await motherboard.setDuty(index: index, percent: percent, role: role)
            recordMotherboard(result)
            guard let reading = result.fans.first(where: { $0.index == index }),
                  !reading.automatic, abs(reading.duty - percent) <= 1 else {
                motherboardError = L10n.text("motherboardWriteUnconfirmed")
                if role == .cpu { radiatorAutomaticOverride = nil }
                return
            }
            motherboardError = nil
            if role == .cpu { radiatorAutomaticOverride = nil }
        } catch {
            if role == .cpu { radiatorAutomaticOverride = nil }
            motherboardSnapshot = nil
            motherboardReadAt = nil
            motherboardInitialized = false
            motherboardError = error.localizedDescription
        }
    }

    func takeRadiatorManualControl() async {
        if let duty = radiatorFan?.duty, (30...100).contains(duty) {
            motherboardCPUTarget = Double(duty)
        }
        await applyMotherboard(.cpu)
    }

    func restoreRadiatorAutomatic() async {
        if !usesTemporaryMotherboardControl {
            guard !motherboardBusy else { return }
            motherboardBusy = true
            radiatorAutomaticOverride = true
            defer { motherboardBusy = false }
            do {
                try await retireTemporaryMotherboardSession()
                let status = try await privilegedFans.restoreCPU()
                fanServiceStatus = status
                fanServiceHealth = .installed
                motherboardCPUTarget = Double(status.duty)
                motherboardError = status.error
                radiatorAutomaticOverride = nil
            } catch {
                fanServiceStatus = nil
                motherboardError = error.localizedDescription
                fanServiceHealth = Self.fanServiceHealth(for: error)
                radiatorAutomaticOverride = nil
            }
            return
        }
        guard let index = settingsStore.value.motherboardMapping?.confirmedIndex(for: .cpu),
              motherboardInitialized, !motherboardBusy else { return }
        motherboardBusy = true
        radiatorAutomaticOverride = true
        defer { motherboardBusy = false }
        do {
            let result = try await motherboard.restoreAutomatic(index: index)
            recordMotherboard(result)
            guard let reading = result.fans.first(where: { $0.index == index }), reading.automatic else {
                motherboardError = L10n.text("motherboardRestoreUnconfirmed")
                radiatorAutomaticOverride = nil
                return
            }
            motherboardCPUTarget = Double(reading.duty)
            motherboardError = nil
            radiatorAutomaticOverride = nil
        } catch {
            radiatorAutomaticOverride = nil
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

    func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
    }
}
