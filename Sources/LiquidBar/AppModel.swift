import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = DeviceSnapshot.unavailable
    @Published private(set) var cpuTemperature: Double?
    @Published private(set) var severity: AlertSeverity = .normal
    @Published private(set) var lastError: String?
    @Published private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    @Published var fanTargets = [50.0, 50.0, 50.0]
    @Published var pumpTarget = 70.0
    @Published var selectedRange: ChartRange = .fifteenMinutes
    @Published var popoverOpen = false
    @Published var busy = false

    let settingsStore: SettingsStore
    let historyStore: HistoryStore
    let notifications = NotificationManager()

    private let liquidctl = LiquidctlService()
    private let smc = SMCReader()
    private var cpuTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?
    private var failureStartedAt: Date?
    private var didNotifyDeviceFailure = false
    private var candidateSeverity: AlertSeverity = .normal
    private var candidateStartedAt = Date()
    private var recoveryStartedAt: Date?
    private var emergencyRestore: (fans: [Int], pump: Int)?
    private var lastHistoryAt = Date.distantPast
    private var started = false

    init(settingsStore: SettingsStore? = nil, historyStore: HistoryStore? = nil) {
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
        deviceTask?.cancel()
    }

    var menuBarText: String {
        let cpu = cpuTemperature.map { String(format: "%.0f°", $0) } ?? "--°"
        let fan = snapshot.maximumFanRPM.map(String.init) ?? "--"
        let pump = snapshot.pumpRPM.map(String.init) ?? "--"
        return "CPU \(cpu)  F \(fan)  P \(pump)"
    }

    var chartSamples: [HistorySample] {
        historyStore.samples(in: selectedRange)
    }

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
        Task { await restoreSavedCoolingState() }
    }

    func stop() {
        cpuTask?.cancel()
        deviceTask?.cancel()
        historyStore.flush()
        Task { await liquidctl.stop() }
        AppLogger.shared.log("LiquidBar stopped")
    }

    func setPopoverOpen(_ open: Bool) {
        popoverOpen = open
    }

    func refreshNow() {
        Task { await refreshDevice() }
        refreshCPU()
    }

    func handleWake() {
        Task {
            busy = true
            defer { busy = false }
            do {
                try await liquidctl.reconnect()
                await restoreSavedCoolingState()
            } catch {
                lastError = error.localizedDescription
                AppLogger.shared.log("wake recovery failed: \(error.localizedDescription)")
            }
        }
    }

    func applyFan(index: Int) {
        guard fanTargets.indices.contains(index), !busy else { return }
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
        guard !busy else { return }
        let duty = min(100, max(50, Int(pumpTarget.rounded())))
        pumpTarget = Double(duty)
        settingsStore.value.lastPreset = nil
        settingsStore.value.manualPumpDuty = duty
        Task { await performWrite { try await self.liquidctl.setPump(duty: duty) } }
    }

    func applyPreset(_ id: PresetID) {
        guard let preset = settingsStore.value.presets[id], !busy else { return }
        fanTargets = Array(repeating: Double(preset.fanDuty), count: 3)
        pumpTarget = Double(preset.pumpDuty)
        settingsStore.value.lastPreset = id
        settingsStore.value.manualFanDuty = Array(repeating: preset.fanDuty, count: 3)
        settingsStore.value.manualPumpDuty = preset.pumpDuty
        Task {
            await performWrite {
                try await self.liquidctl.apply(
                    fans: Array(repeating: preset.fanDuty, count: 3),
                    pump: preset.pumpDuty
                )
            }
        }
    }

    func identifyFan(_ index: Int) {
        guard !busy else { return }
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
        LiquidBar 0.1.2
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        CPU: \(cpuTemperature.map { String(format: "%.1f °C", $0) } ?? "unavailable")
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
        cpuTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshCPU()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        deviceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshDevice()
                let seconds: UInt64 = self.popoverOpen ? 2 : 5
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    private func refreshCPU() {
        cpuTemperature = smc?.cpuTemperature()
        evaluateThermalState()
    }

    private func refreshDevice() async {
        do {
            let newSnapshot = try await liquidctl.status()
            snapshot = newSnapshot
            lastError = nil
            failureStartedAt = nil
            didNotifyDeviceFailure = false
            synchronizeTargetsIfNeeded(with: newSnapshot)
            if Date().timeIntervalSince(lastHistoryAt) >= 5 {
                historyStore.append(cpuTemperature: cpuTemperature, snapshot: newSnapshot)
                lastHistoryAt = Date()
            }
            evaluateThermalState()
        } catch {
            snapshot.connected = false
            snapshot.timestamp = Date()
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

    private func synchronizeTargetsIfNeeded(with snapshot: DeviceSnapshot) {
        guard !busy else { return }
        if settingsStore.value.lastPreset == nil {
            for index in 0..<3 {
                if let duty = snapshot.fanDuty[index] { fanTargets[index] = Double(duty) }
            }
            if let duty = snapshot.pumpDuty { pumpTarget = Double(duty) }
        }
    }

    private func applyManualState() {
        let fans = fanTargets.map { min(100, max(30, Int($0.rounded()))) }
        let pump = min(100, max(50, Int(pumpTarget.rounded())))
        settingsStore.value.lastPreset = nil
        settingsStore.value.manualFanDuty = fans
        settingsStore.value.manualPumpDuty = pump
        Task { await performWrite { try await self.liquidctl.apply(fans: fans, pump: pump) } }
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
        await performWrite { try await self.liquidctl.apply(fans: fans, pump: pump) }
    }

    private func performWrite(_ operation: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await operation()
            AppLogger.shared.log("cooling setting applied")
            await refreshDevice()
        } catch {
            lastError = error.localizedDescription
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
            Task { await performWrite { try await self.liquidctl.apply(fans: [100, 100, 100], pump: 100) } }
        } else if newSeverity == .normal, let restore = emergencyRestore {
            emergencyRestore = nil
            fanTargets = restore.fans.map(Double.init)
            pumpTarget = Double(restore.pump)
            Task { await performWrite { try await self.liquidctl.apply(fans: restore.fans, pump: restore.pump) } }
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
