import AppKit
import SwiftUI

struct MotherboardSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore

    @State private var showInstaller = false
    @State private var showPumpControls = false

    var body: some View {
        Group {
            SettingsCard(title: L10n.text("fanService"), subtitle: fanServiceSubtitle) {
            HStack(spacing: 8) {
                StatusDot(color: fanServiceColor)
                Text(fanServiceStatusText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryInk)
                Spacer()
                Button(L10n.text("refresh"), action: model.initializeMotherboard)
                    .buttonStyle(ClaudeQuietButtonStyle())
                    .disabled(model.motherboardBusy)
                switch model.fanServiceHealth {
                case .needsUpdate:
                    Button(L10n.text("updateFanService")) { showInstaller = true }
                        .buttonStyle(ClaudePrimaryButtonStyle())
                case .notInstalled:
                    Button(L10n.text("installFanService")) { showInstaller = true }
                        .buttonStyle(ClaudePrimaryButtonStyle())
                case .needsRestart:
                    Button(L10n.text("restartApp")) { model.restartApplication() }
                        .buttonStyle(ClaudePrimaryButtonStyle())
                case .installed:
                    EmptyView()
                }
            }

            if !model.persistentFanServiceInstalled {
                Hairline()
                SettingRow(title: L10n.text("temporaryFanSession"), detail: L10n.text("temporaryFanSessionHelp")) {
                    Toggle("", isOn: Binding(
                        get: { store.value.temporaryMotherboardControl == true },
                        set: { enabled in Task { await model.setTemporaryMotherboardControl(enabled) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(model.motherboardBusy)
                }
            }

            if let reason = model.radiatorControlReason {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryInk)
            }
            if !model.usesTemporaryMotherboardControl, let error = model.motherboardError {
                Text(error).font(.system(size: 10)).foregroundStyle(Theme.warm)
            }
        }

            if model.usesTemporaryMotherboardControl {
                temporaryMappingCard
            }
        }
        .sheet(isPresented: $showInstaller) {
            FanServiceInstallerSheet(model: model)
        }
    }

    private var fanServiceSubtitle: String {
        switch model.fanServiceHealth {
        case .installed: return L10n.text("fanServiceInstalled")
        case .needsUpdate: return L10n.text("fanServiceUpdateHelp")
        case .needsRestart: return L10n.text("fanServiceRestartHelp")
        case .notInstalled: return L10n.text("fanServiceInstallHelp")
        }
    }

    private var fanServiceStatusText: String {
        switch model.fanServiceHealth {
        case .installed: return L10n.text("installed")
        case .needsUpdate: return L10n.text("serviceNeedsUpdate")
        case .needsRestart: return L10n.text("serviceNeedsRestart")
        case .notInstalled: return L10n.text("notInstalled")
        }
    }

    private var fanServiceColor: Color {
        switch model.fanServiceHealth {
        case .installed: return Theme.cool
        case .needsUpdate, .needsRestart: return Theme.warm
        case .notInstalled: return Theme.tertiaryInk
        }
    }

    private var temporaryMappingCard: some View {
        SettingsCard(title: L10n.text("motherboardFans"), subtitle: L10n.text("motherboardMappingHelp")) {
            HStack(spacing: 8) {
                Button(L10n.text("detectMotherboard"), action: model.initializeMotherboard)
                    .buttonStyle(ClaudeSecondaryButtonStyle())
                    .disabled(model.motherboardBusy)
                Spacer()
                Button(L10n.text("restoreBIOS"), action: model.restoreMotherboard)
                    .buttonStyle(ClaudeSecondaryButtonStyle())
                    .disabled(model.motherboardBusy)
            }

            if let snapshot = model.motherboardSnapshot {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(snapshot.driverVersion) · \(snapshot.chipID.map { String(format: "0x%04llX", $0) } ?? "--")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.tertiaryInk)
                        Spacer()
                    }
                    ForEach(snapshot.fans) { fan in
                        HStack(spacing: 8) {
                            Text("#\(fan.index)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.tertiaryInk)
                                .frame(width: 24, alignment: .leading)
                            Text(fan.name)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            Text("\(fan.rpm) RPM")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.secondaryInk)
                            Text("\(fan.duty)%")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.secondaryInk)
                                .frame(width: 34, alignment: .trailing)
                            Pill(
                                text: fan.automatic ? L10n.text("automatic") : L10n.text("manual"),
                                color: fan.automatic ? Theme.cool : Theme.accent
                            )
                        }
                    }
                }
                .padding(10)
                .background(Theme.surfaceMuted.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Hairline()

                mappingPicker("CPU_FAN", index: mapping.cpuIndex, fans: snapshot.fans)
                HStack(spacing: 8) {
                    Button("CPU_FAN " + L10n.text("testIncrease")) { model.testMotherboard(.cpu) }
                        .buttonStyle(ClaudeSecondaryButtonStyle())
                        .disabled(model.motherboardBusy || mapping.wrappedValue.cpuIndex == nil)
                    Spacer()
                }
                SettingRow(title: L10n.text("cpuMappingConfirmed")) {
                    Toggle("", isOn: Binding(
                        get: { model.radiatorMappingConfirmed },
                        set: model.confirmRadiatorMapping
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(model.motherboardBusy || mapping.wrappedValue.cpuIndex == nil ||
                              mapping.wrappedValue.cpuIndex == mapping.wrappedValue.pumpIndex)
                }
                if let result = model.motherboardTestResult {
                    Text(result)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.secondaryInk)
                }

                Hairline()
                motherboardSlider(role: .cpu, title: "CPU_FAN", value: $model.motherboardCPUTarget, minimum: 30)

                DisclosureGroup(isExpanded: $showPumpControls) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("advancedPumpHelp"))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                        mappingPicker("AIO_PUMP", index: mapping.pumpIndex, fans: snapshot.fans)
                        HStack(spacing: 8) {
                            Button("AIO_PUMP " + L10n.text("testIncrease")) { model.testMotherboard(.pump) }
                                .buttonStyle(ClaudeSecondaryButtonStyle())
                                .disabled(model.motherboardBusy || mapping.wrappedValue.pumpIndex == nil)
                            Spacer()
                        }
                        SettingRow(title: L10n.text("mappingConfirmed")) {
                            Toggle("", isOn: mapping.confirmed)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                        if mapping.wrappedValue.cpuIndex == mapping.wrappedValue.pumpIndex && mapping.wrappedValue.cpuIndex != nil {
                            Text(L10n.text("mappingConflict"))
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.warm)
                        }
                        motherboardSlider(role: .pump, title: "AIO_PUMP", value: $model.motherboardPumpTarget, minimum: 80)
                    }
                    .padding(.top, 6)
                } label: {
                    Text(L10n.text("advancedPump"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondaryInk)
                }
            }

            if let error = model.motherboardError {
                Text(error).font(.system(size: 10)).foregroundStyle(Theme.warm)
            }
        }
    }

    private var mapping: Binding<MotherboardMappingSettings> {
        Binding(
            get: { store.value.motherboardMapping ?? MotherboardMappingSettings() },
            set: { store.value.motherboardMapping = $0 }
        )
    }

    private func mappingPicker(_ label: String, index: Binding<Int?>, fans: [MotherboardFanReading]) -> some View {
        SettingRow(title: label) {
            Picker("", selection: Binding(get: { index.wrappedValue ?? -1 }, set: {
                index.wrappedValue = $0 < 0 ? nil : $0
                store.value.motherboardMapping?.confirmed = false
                store.value.motherboardMapping?.confirmedCPUIndex = nil
            })) {
                Text(L10n.text("unmapped")).tag(-1)
                ForEach(fans) { fan in Text("#\(fan.index) \(fan.name)").tag(fan.index) }
            }
            .labelsHidden()
            .frame(width: 190)
        }
    }

    private func motherboardSlider(
        role: MotherboardFanRole,
        title: String,
        value: Binding<Double>,
        minimum: Double
    ) -> some View {
        let valid = mapping.wrappedValue.confirmedIndex(for: role) != nil && !model.motherboardBusy
        return VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(Int(value.wrappedValue))%")
                    .font(Typography.numeral(11))
                    .foregroundStyle(Theme.accent)
                Button(L10n.text("apply")) { Task { await model.applyMotherboard(role) } }
                    .buttonStyle(ClaudeQuietButtonStyle())
            }
            Slider(value: value, in: minimum...100, step: 1)
                .tint(Theme.accent)
                .controlSize(.small)
        }
        .disabled(!valid)
    }
}

struct FanServiceInstallerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel

    private enum Stage: Equatable {
        case confirm
        case working
        case restart
        case failed(String)
    }

    @State private var stage: Stage = .confirm

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch stage {
            case .confirm: confirmBody
            case .working: workingBody
            case .restart: restartBody
            case .failed(let message): failedBody(message)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.canvas)
        .interactiveDismissDisabled(stage != .confirm)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "fanblades")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("installFanService"))
                    .font(Typography.wordmark(16))
                    .foregroundStyle(Theme.ink)
                Text(L10n.text("installerSubtitle"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
    }

    private var confirmBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("installerConfirmNote"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                step(1, L10n.text("installerStepPassword"))
                step(2, L10n.text("installerStepInstall"))
                step(3, L10n.text("installerStepRestart"))
            }

            EmptyHint(text: L10n.text("installerScope"))

            HStack(spacing: 8) {
                Spacer()
                Button(L10n.text("cancel"), action: { dismiss() })
                    .buttonStyle(ClaudeSecondaryButtonStyle())
                Button(L10n.text("continueInstall"), action: begin)
                    .buttonStyle(ClaudePrimaryButtonStyle())
                    .disabled(!InAppFanServiceInstaller.isAvailable)
            }
        }
    }

    private var workingBody: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(L10n.text("installerWorking"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private var restartBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.cool)
                Text(L10n.text("installerRestartTitle"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            Text(L10n.text("installerRestartBody"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.text("restartApp")) {
                    InAppFanServiceInstaller.relaunchAndExit()
                }
                .buttonStyle(ClaudePrimaryButtonStyle())
            }
        }
    }

    private func failedBody(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            NoticeBanner(text: message)
            Text(L10n.text("installerRestartHint"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.text("restartApp")) {
                    InAppFanServiceInstaller.relaunchAndExit()
                }
                .buttonStyle(ClaudePrimaryButtonStyle())
            }
        }
    }

    private func begin() {
        stage = .working
        Task { @MainActor in
            guard await model.stop(ignoringFanService: true) else {
                stage = .failed(L10n.text("installerStoppedUnconfirmed"))
                return
            }
            InAppFanServiceInstaller.install { result in
                DispatchQueue.main.async {
                    // The authorization dialog can leave another app in front; bring
                    // LiquidBar back so the restart prompt is visible immediately.
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSApplication.shared.keyWindow?.makeKeyAndOrderFront(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        NSApplication.shared.keyWindow?.makeKeyAndOrderFront(nil)
                    }
                    switch result {
                    case .success:
                        model.completeFanServiceInstall()
                        stage = .restart
                    case .failure(let error):
                        stage = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 16, height: 16)
                .background(Theme.accentFill, in: Circle())
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
