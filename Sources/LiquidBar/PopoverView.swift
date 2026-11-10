import Foundation
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    let openSettings: () -> Void
    let openFanService: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            header
            if let alert = fanServiceAlert {
                FanServiceAlertBanner(
                    title: alert.title,
                    message: alert.message,
                    actionTitle: L10n.text("fixNow"),
                    tint: Theme.hot,
                    action: openFanService
                )
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 10) {
                    sensorRow
                    chartCard
                    if model.snapshot.hasSmart || model.showRadiatorControl { presetRow }
                    if model.snapshot.hasSmart { smartCard }
                    if model.snapshot.hasPump { krakenCard }
                    if model.showRadiatorControl { motherboardCard }
                    if let gpu = model.gpuReading { gpuCard(gpu) }
                    if !model.snapshot.hasCoolingControl && model.gpuReading == nil { noDevicesCard }
                }
                .frame(width: 380)
                if showLightingColumn {
                    VStack(spacing: 10) {
                        if lightingRoles.count > 1 {
                            LightingAllView(model: model, store: store)
                        }
                        if model.snapshot.supports("smart", "lighting") {
                            LightingGroupView(
                                model: model, store: store, role: "smart",
                                title: L10n.text("caseLighting")
                            )
                        }
                        if model.snapshot.supports("aura", "lighting") {
                            LightingGroupView(
                                model: model, store: store, role: "aura",
                                title: L10n.text("coolerLighting")
                            )
                        }
                    }
                    .frame(width: 360)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            if let error = model.lastError {
                NoticeBanner(text: error)
            }
            footer
        }
        .padding(12)
        .frame(width: showLightingColumn ? 780 : 404)
        .background(Theme.canvas)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("LiquidBar")
                    .font(Typography.wordmark(15))
                    .foregroundStyle(Theme.ink)
                Text(deviceSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(1)
            }
            Spacer()
            if model.busy {
                ProgressView().controlSize(.small)
            }
            Pill(
                text: model.snapshot.connected ? L10n.text("connected") : L10n.text("offlineShort"),
                color: model.snapshot.connected ? Theme.cool : Theme.secondaryInk,
                icon: model.snapshot.connected ? "checkmark.circle.fill" : "circle.dashed"
            )
            Button(action: model.refreshNow) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(ClaudeQuietButtonStyle())
            .help(L10n.text("refresh"))
        }
    }

    private var deviceSubtitle: String {
        let names = model.snapshot.visibleDeviceRoles.map(deviceName)
        return names.isEmpty ? L10n.text("noDevices") : names.joined(separator: " · ")
    }

    private func deviceName(_ role: String) -> String {
        switch role {
        case "smart": return "Smart Device V2"
        case "aura": return "ASUS AURA"
        case "ld": return "DeepCool LD"
        default: return "Kraken"
        }
    }

    private var sensorRow: some View {
        HStack(spacing: 8) {
            SensorTile(
                title: L10n.text("cpu"),
                value: temperature(model.cpuTemperature),
                symbol: "cpu",
                tint: Theme.sensorColor(for: severityForCPU)
            )
            if model.gpuReading != nil {
                SensorTile(
                    title: "GPU",
                    value: temperature(model.gpuReading?.temperature),
                    symbol: "rectangle.on.rectangle",
                    tint: Theme.sensorColor(for: gpuSeverity)
                )
            }
            if model.snapshot.hasLiquidSensor {
                SensorTile(
                    title: L10n.text("liquid"),
                    value: temperature(model.snapshot.liquidTemperature),
                    symbol: "drop.fill",
                    tint: Theme.sensorColor(for: severityForLiquid)
                )
            } else {
                SensorTile(
                    title: L10n.text("cpuPower"),
                    value: model.cpuPower.map { String(format: "%.0f", $0) } ?? "--",
                    unit: "W",
                    symbol: "bolt.fill",
                    tint: Theme.accent
                )
            }
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("history"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Picker("", selection: $model.selectedRange) {
                    ForEach(ChartRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 186)
            }
            TemperatureChart(
                samples: model.chartSamples,
                showsLiquid: model.snapshot.hasLiquidSensor,
                showsGPU: model.gpuReading != nil
            )
            .frame(height: 82)
            ChartLegend(
                showsLiquid: model.snapshot.hasLiquidSensor,
                showsGPU: model.gpuReading != nil
            )
        }
        .cardSurface(padding: 12)
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(PresetID.allCases) { id in
                let preset = store.value.presets[id] ?? AppSettings.defaultPreset(id)
                PresetChip(
                    title: L10n.preset(id),
                    detail: presetDetail(preset),
                    selected: store.value.lastPreset == id
                ) {
                    model.applyPreset(id)
                }
                .disabled(model.busy || (!model.snapshot.hasSmart && !model.snapshot.hasPump))
            }
        }
    }

    private func presetDetail(_ preset: CoolingPreset) -> String {
        var values: [String] = []
        if model.snapshot.hasSmart { values.append("\(preset.fanDuty)%") }
        if model.showRadiatorControl && model.radiatorMappingConfirmed {
            values.append("\(preset.radiatorDuty ?? 55)%")
        }
        return values.isEmpty ? "\(preset.fanDuty)%" : values.joined(separator: " · ")
    }

    private func deviceHeader<Content: View>(
        symbol: String,
        title: String,
        tint: Color = Theme.secondaryInk,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 6)
            trailing()
        }
    }

    private var smartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            deviceHeader(symbol: "fanblades", title: "NZXT Smart Device V2") {
                HStack(spacing: 7) {
                    if smartFanCount > 1 {
                        Toggle(L10n.text("linkShort"), isOn: linkedFansBinding)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .tint(Theme.accent)
                            .font(.system(size: 10))
                    }
                    Text(L10n.text("curveShort"))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.secondaryInk)
                    ModeSwitch(isAutomatic: .constant(curveEnabled), enabled: !model.busy) { automatic in
                        model.setCurveEnabled(automatic)
                    }
                    .help(L10n.text("fanCurveSharedHelp"))
                }
            }
            ForEach(0..<3, id: \.self) { index in
                FanControlRow(
                    name: store.value.fanNames[index],
                    symbol: "fan.fill",
                    target: fanBinding(index),
                    minimum: 30,
                    rpm: model.snapshot.fanRPM[index],
                    actualDuty: model.snapshot.fanDuty[index],
                    noTach: model.snapshot.fanModes[index] == nil && model.snapshot.fanRPM[index] == 0,
                    enabled: !model.busy,
                    mode: curveEnabled ? L10n.text("automatic") : L10n.text("manual"),
                    modeColor: curveEnabled ? Theme.cool : Theme.secondaryInk,
                    onCommit: { model.applyFan(index: index) }
                )
            }
        }
        .cardSurface(padding: 11)
    }

    private var krakenCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            deviceHeader(symbol: "drop.fill", title: "NZXT Kraken", tint: Theme.liquidLine) {
                HStack(spacing: 7) {
                    if let liquid = model.snapshot.liquidTemperature {
                        Pill(text: String(format: "%.0f°C", liquid), color: Theme.liquidLine)
                    }
                    ModeSwitch(isAutomatic: .constant(model.pumpAutomatic), enabled: !model.busy) { automatic in
                        model.setPumpAutomatic(automatic)
                    }
                    .help(L10n.text("pumpAutoHelp"))
                }
            }
            FanControlRow(
                name: L10n.text("pump"),
                symbol: "drop.circle.fill",
                target: $model.pumpTarget,
                minimum: 50,
                rpm: model.snapshot.pumpRPM,
                actualDuty: model.snapshot.pumpDuty,
                enabled: !model.busy,
                onCommit: model.applyPump
            )
        }
        .cardSurface(padding: 11)
    }

    private var motherboardCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            deviceHeader(symbol: "cpu", title: L10n.text("motherboardFan")) {
                radiatorHeaderControl
            }
            FanControlRow(
                name: L10n.text("radiatorFan"),
                symbol: "wind",
                target: $model.motherboardCPUTarget,
                minimum: 30,
                rpm: model.radiatorFan?.rpm,
                actualDuty: model.radiatorFan?.duty,
                enabled: model.canControlRadiator,
                onCommit: { Task { await model.applyMotherboard(.cpu) } }
            )
            if model.motherboardBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L10n.text(model.usesTemporaryMotherboardControl ? "motherboardWorking" : "fanServiceWorking"))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.fanServiceHealth == .needsRestart {
                Text(L10n.text("fanServiceRestartHelp"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warm)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let reason = model.radiatorControlReason {
                Text(reason)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = model.motherboardError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warm)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .cardSurface(padding: 11)
    }

    @ViewBuilder
    private var radiatorHeaderControl: some View {
        if model.fanServiceHealth == .needsRestart {
            Button(L10n.text("restartApp")) { model.restartApplication() }
                .buttonStyle(ClaudeQuietButtonStyle())
        } else if model.fanServiceHealth == .needsUpdate {
            Button(L10n.text("updateFanService"), action: openFanService)
                .buttonStyle(ClaudeQuietButtonStyle())
        } else if !model.radiatorMappingConfirmed {
            Button(
                L10n.text(model.usesTemporaryMotherboardControl ? "confirmRadiatorInSettings" : "installFanService"),
                action: openSettings
            )
            .buttonStyle(ClaudeQuietButtonStyle())
        } else if model.radiatorFan == nil {
            Button(action: model.initializeMotherboard) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(ClaudeQuietButtonStyle())
            .disabled(model.motherboardBusy)
        } else {
            ModeSwitch(
                isAutomatic: .constant(model.radiatorAutomaticOverride ?? model.radiatorFan?.automatic == true),
                enabled: model.canControlRadiator
            ) { automatic in
                Task {
                    if automatic {
                        await model.restoreRadiatorAutomatic()
                    } else {
                        await model.takeRadiatorManualControl()
                    }
                }
            }
            .help(L10n.text("radiatorAutoHelp"))
        }
    }

    private func gpuCard(_ gpu: GPUReading) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            deviceHeader(symbol: "rectangle.on.rectangle", title: gpu.name, tint: Theme.gpuLine) {
                Pill(text: L10n.text("monitorOnly"), color: Theme.gpuLine)
                    .help(L10n.text("gpuMonitorOnly"))
            }
            HStack(spacing: 12) {
                Text(temperature(gpu.temperature) + " °C")
                    .foregroundStyle(Theme.gpuLine)
                Text((gpu.fanRPM.map(String.init) ?? "--") + " RPM")
                    .foregroundStyle(Theme.secondaryInk)
                Text(gpu.fanPercent.map { String(format: "%.0f%%", $0) } ?? "--%")
                    .foregroundStyle(Theme.secondaryInk)
                    .help(L10n.text("gpuPercentHelp"))
                if let power = gpu.powerWatts {
                    Text(String(format: "%.0f W", power))
                        .foregroundStyle(Theme.tertiaryInk)
                }
                Spacer()
            }
            .font(.system(size: 10, design: .monospaced))
        }
        .cardSurface(padding: 11)
    }

    private var noDevicesCard: some View {
        VStack(alignment: .leading) {
            EmptyHint(text: L10n.text("smartDisconnected"))
        }
        .cardSurface(padding: 11)
    }

    private var fanServiceAlert: (title: String, message: String)? {
        switch model.fanServiceHealth {
        case .needsUpdate:
            return (L10n.text("fanServiceAlertUpdateTitle"), L10n.text("fanServiceAlertUpdateBody"))
        case .needsRestart:
            return (L10n.text("fanServiceAlertRestartTitle"), L10n.text("fanServiceAlertRestartBody"))
        case .installed, .notInstalled:
            return nil
        }
    }

    private var lightingRoles: [String] {
        var result: [String] = []
        if model.snapshot.supports("smart", "lighting") { result.append("smart") }
        if model.snapshot.supports("aura", "lighting") { result.append("aura") }
        return result
    }

    private var showLightingColumn: Bool {
        store.value.showLightingInPanel == true && !lightingRoles.isEmpty
    }

    private var curveEnabled: Bool {
        store.value.fanCurve?.enabled == true
    }

    private var smartFanCount: Int {
        (0..<3).filter { index in
            model.snapshot.fanDuty[index] != nil
                || (model.snapshot.fanRPM[index] ?? 0) > 0
                || model.snapshot.fanModes[index] != nil
        }.count
    }

    private var footer: some View {
        HStack(spacing: 4) {
            StatusDot(color: model.snapshot.connected ? Theme.cool : Theme.tertiaryInk)
            Text(model.snapshot.connected ? L10n.text("liveSampling") : L10n.text("offlineShort"))
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryInk)
            Spacer()
            Button(L10n.text("settings"), action: openSettings)
                .buttonStyle(ClaudeQuietButtonStyle())
            Button(L10n.text("quit"), action: quit)
                .buttonStyle(ClaudeQuietButtonStyle())
        }
    }

    private func fanBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { model.fanTargets[index] },
            set: { value in
                if store.value.linkedFans {
                    model.fanTargets = Array(repeating: value, count: 3)
                } else {
                    model.fanTargets[index] = value
                }
            }
        )
    }

    private var linkedFansBinding: Binding<Bool> {
        Binding(
            get: { store.value.linkedFans },
            set: { store.value.linkedFans = $0 }
        )
    }

    private var severityForCPU: AlertSeverity {
        guard let value = model.cpuTemperature else { return .normal }
        let thresholds = store.value.thresholds
        if value >= thresholds.cpuCritical { return .critical }
        if value >= thresholds.cpuWarning { return .warning }
        return .normal
    }

    private var severityForLiquid: AlertSeverity {
        guard let value = model.snapshot.liquidTemperature else { return .normal }
        let thresholds = store.value.thresholds
        if value >= thresholds.liquidCritical { return .critical }
        if value >= thresholds.liquidWarning { return .warning }
        return .normal
    }

    private var gpuSeverity: AlertSeverity {
        guard let value = model.gpuReading?.temperature else { return .normal }
        if value >= MenuBarTemperatureItem.gpuHot { return .critical }
        if value >= MenuBarTemperatureItem.gpuWarm { return .warning }
        return .normal
    }

    private func temperature(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f", value)
    }
}
