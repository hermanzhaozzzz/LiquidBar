import ServiceManagement
import SwiftUI
import UserNotifications

struct PopoverView: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            header
            temperatureChart
            presets
            Divider()
            controls
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 390)
    }

    private var header: some View {
        HStack(spacing: 10) {
            SensorCard(
                title: L10n.text("cpu"),
                value: temperature(model.cpuTemperature),
                symbol: "cpu",
                severity: severityForCPU
            )
            SensorCard(
                title: L10n.text("liquid"),
                value: temperature(model.snapshot.liquidTemperature),
                symbol: "drop.fill",
                severity: severityForLiquid
            )
            SensorCard(
                title: L10n.text("pump"),
                value: model.snapshot.pumpRPM.map { "\($0)" } ?? "--",
                symbol: "gauge.with.dots.needle.50percent",
                severity: .normal,
                suffix: "RPM"
            )
        }
    }

    private var temperatureChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("history"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("", selection: $model.selectedRange) {
                    ForEach(ChartRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 205)
            }

            TemperatureHistoryChart(samples: model.chartSamples)
            .frame(height: 105)
        }
    }

    private var presets: some View {
        HStack(spacing: 7) {
            ForEach(PresetID.allCases) { id in
                Button(L10n.preset(id)) { model.applyPreset(id) }
                    .buttonStyle(PresetButtonStyle(selected: model.settingsStore.value.lastPreset == id))
                    .disabled(model.busy)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 11) {
            Toggle(L10n.text("linkedFans"), isOn: linkedFansBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)

            ForEach(0..<3, id: \.self) { index in
                SpeedSlider(
                    name: model.settingsStore.value.fanNames[index],
                    symbol: "fan.fill",
                    target: fanBinding(index),
                    minimum: 30,
                    rpm: model.snapshot.fanRPM[index],
                    enabled: model.snapshot.connected && !model.busy,
                    onCommit: { model.applyFan(index: index) }
                )
            }
            SpeedSlider(
                name: L10n.text("pump"),
                symbol: "drop.circle.fill",
                target: $model.pumpTarget,
                minimum: 50,
                rpm: model.snapshot.pumpRPM,
                enabled: model.snapshot.connected && !model.busy,
                onCommit: model.applyPump
            )
        }
    }

    private var footer: some View {
        HStack {
            Circle()
                .fill(model.snapshot.connected ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(model.snapshot.connected ? L10n.text("connected") : L10n.text("offline"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: model.refreshNow) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            Button(L10n.text("settings"), action: openSettings)
                .buttonStyle(.plain)
            Button(L10n.text("quit"), action: quit)
                .buttonStyle(.plain)
        }
    }

    private func fanBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { model.fanTargets[index] },
            set: { value in
                if model.settingsStore.value.linkedFans {
                    model.fanTargets = Array(repeating: value, count: 3)
                } else {
                    model.fanTargets[index] = value
                }
            }
        )
    }

    private var linkedFansBinding: Binding<Bool> {
        Binding(
            get: { model.settingsStore.value.linkedFans },
            set: { model.settingsStore.value.linkedFans = $0 }
        )
    }

    private var severityForCPU: AlertSeverity {
        guard let value = model.cpuTemperature else { return .normal }
        let thresholds = model.settingsStore.value.thresholds
        if value >= thresholds.cpuCritical { return .critical }
        if value >= thresholds.cpuWarning { return .warning }
        return .normal
    }

    private var severityForLiquid: AlertSeverity {
        guard let value = model.snapshot.liquidTemperature else { return .normal }
        let thresholds = model.settingsStore.value.thresholds
        if value >= thresholds.liquidCritical { return .critical }
        if value >= thresholds.liquidWarning { return .warning }
        return .normal
    }

    private func temperature(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "--"
    }
}

private struct TemperatureHistoryChart: View {
    let samples: [HistorySample]

    private var limits: ClosedRange<Double> {
        let values = samples.flatMap { [$0.cpuTemperature, $0.liquidTemperature].compactMap { $0 } }
        guard let minimum = values.min(), let maximum = values.max() else { return 20...80 }
        let padding = max(3, (maximum - minimum) * 0.12)
        let lower = floor((minimum - padding) / 5) * 5
        let upper = ceil((maximum + padding) / 5) * 5
        return lower...(upper > lower ? upper : lower + 10)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Canvas { context, size in
                for fraction in [0.0, 0.5, 1.0] {
                    var grid = Path()
                    let y = size.height * fraction
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(grid, with: .color(.secondary.opacity(0.16)), lineWidth: 0.5)
                }
                draw(\.cpuTemperature, color: .cyan, context: &context, size: size)
                draw(\.liquidTemperature, color: .blue, context: &context, size: size)
            }
            if samples.isEmpty {
                Text("--")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack {
                Text("\(Int(limits.upperBound))°")
                Spacer()
                Text("\(Int(limits.lowerBound))°")
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
        }
        .accessibilityLabel(L10n.text("history"))
    }

    private func draw(
        _ keyPath: KeyPath<HistorySample, Double?>,
        color: Color,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        guard samples.count > 1 else { return }
        let start = samples.first!.timestamp.timeIntervalSinceReferenceDate
        let end = samples.last!.timestamp.timeIntervalSinceReferenceDate
        let duration = max(1, end - start)
        let span = limits.upperBound - limits.lowerBound
        var path = Path()
        var hasPoint = false

        for sample in samples {
            guard let value = sample[keyPath: keyPath] else {
                hasPoint = false
                continue
            }
            let elapsed = sample.timestamp.timeIntervalSinceReferenceDate - start
            let x = size.width * elapsed / duration
            let normalized = (value - limits.lowerBound) / span
            let y = size.height * (1 - min(1, max(0, normalized)))
            let point = CGPoint(x: x, y: y)
            if hasPoint { path.addLine(to: point) } else { path.move(to: point) }
            hasPoint = true
        }
        context.stroke(path, with: .color(color), lineWidth: 1.6)
    }
}

private struct SensorCard: View {
    let title: String
    let value: String
    let symbol: String
    let severity: AlertSeverity
    var suffix = "°C"

    var color: Color {
        switch severity {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(suffix)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SpeedSlider: View {
    let name: String
    let symbol: String
    @Binding var target: Double
    let minimum: Double
    let rpm: Int?
    let enabled: Bool
    let onCommit: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Label(name, systemImage: symbol)
                    .font(.subheadline)
                Spacer()
                Text(rpm.map { "\($0) RPM" } ?? "-- RPM")
                    .foregroundStyle(.secondary)
                    .font(.caption.monospacedDigit())
                Text("\(Int(target.rounded()))%")
                    .frame(width: 40, alignment: .trailing)
                    .font(.caption.monospacedDigit())
            }
            Slider(value: $target, in: minimum...100, step: 1, onEditingChanged: { editing in
                if !editing { onCommit() }
            })
            .disabled(!enabled)
        }
    }
}

private struct PresetButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.09),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var notifications: NotificationManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox(L10n.text("status")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(L10n.text("launchAtLogin"), isOn: launchBinding)
                        if model.loginItemStatus == .requiresApproval {
                            Text(L10n.text("loginNeedsApproval"))
                                .font(.caption).foregroundStyle(.orange)
                            Button(L10n.text("openLoginItems"), action: model.openLoginItemsSettings)
                        }
                        Text(model.menuBarText)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox(L10n.text("fanNames")) {
                    VStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { index in
                            HStack {
                                TextField("Fan \(index + 1)", text: fanNameBinding(index))
                                Button(L10n.text("identify")) { model.identifyFan(index) }
                                    .disabled(model.busy || !model.snapshot.connected)
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox(L10n.text("presets")) {
                    VStack(spacing: 10) {
                        ForEach(PresetID.allCases) { id in
                            PresetEditor(id: id, preset: presetBinding(id))
                        }
                    }
                    .padding(6)
                }

                GroupBox(L10n.text("alerts")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(L10n.text("systemNotifications"), isOn: notificationBinding)
                        Toggle(L10n.text("criticalSound"), isOn: setting(\.criticalSoundEnabled))
                            .disabled(!store.value.notificationsEnabled)
                        Toggle(L10n.text("automaticBoost"), isOn: setting(\.automaticEmergencyBoost))
                        ThresholdEditor(settings: $store.value.thresholds)
                        if notifications.authorizationStatus == .denied {
                            Text(L10n.text("notificationDenied"))
                                .font(.caption).foregroundStyle(.orange)
                            Button(L10n.text("openNotificationSettings"), action: model.openNotificationSettings)
                        }
                    }
                    .padding(6)
                }

                GroupBox(L10n.text("diagnostics")) {
                    HStack {
                        Button(L10n.text("copyDiagnostics"), action: model.copyDiagnostics)
                        Button(L10n.text("clearLog"), action: model.clearLog)
                        Spacer()
                        Text("LiquidBar 0.1.3")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 650)
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { store.value.launchAtLogin },
            set: { model.updateLaunchAtLogin(enabled: $0) }
        )
    }

    private var notificationBinding: Binding<Bool> {
        Binding(
            get: { store.value.notificationsEnabled },
            set: { model.updateNotifications(enabled: $0) }
        )
    }

    private func fanNameBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { store.value.fanNames[index] },
            set: { store.value.fanNames[index] = $0 }
        )
    }

    private func presetBinding(_ id: PresetID) -> Binding<CoolingPreset> {
        Binding(
            get: { store.value.presets[id] ?? AppSettings.defaultPreset(id) },
            set: { store.value.presets[id] = $0 }
        )
    }

    private func setting(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.value[keyPath: keyPath] },
            set: { store.value[keyPath: keyPath] = $0 }
        )
    }
}

private struct PresetEditor: View {
    let id: PresetID
    @Binding var preset: CoolingPreset

    var body: some View {
        HStack {
            Text(L10n.preset(id)).frame(width: 75, alignment: .leading)
            Spacer()
            Stepper("Fan \(preset.fanDuty)%", value: $preset.fanDuty, in: 30...100)
                .frame(width: 130)
            Stepper("Pump \(preset.pumpDuty)%", value: $preset.pumpDuty, in: 50...100)
                .frame(width: 150)
        }
        .font(.caption)
    }
}

private struct ThresholdEditor: View {
    @Binding var settings: AlertThresholds

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text(L10n.text("cpuWarning"))
                Stepper("\(Int(settings.cpuWarning))°C", value: $settings.cpuWarning, in: 50...94)
            }
            GridRow {
                Text(L10n.text("cpuCritical"))
                Stepper("\(Int(settings.cpuCritical))°C", value: $settings.cpuCritical, in: 60...95)
            }
            GridRow {
                Text(L10n.text("liquidWarning"))
                Stepper("\(Int(settings.liquidWarning))°C", value: $settings.liquidWarning, in: 30...59)
            }
            GridRow {
                Text(L10n.text("liquidCritical"))
                Stepper("\(Int(settings.liquidCritical))°C", value: $settings.liquidCritical, in: 35...60)
            }
        }
        .font(.caption)
    }
}
