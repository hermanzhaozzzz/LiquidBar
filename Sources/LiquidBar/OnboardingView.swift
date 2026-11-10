import AppKit
import SwiftUI

struct SetupProbe {
    var liquidctlPath: String?
    var cpuTemperature: Double?
    var gpuName: String?
    var fanServiceHealth: FanServiceHealth

    @MainActor
    static func run(using model: AppModel) -> SetupProbe {
        SetupProbe(
            liquidctlPath: LiquidctlService.availablePython?.path,
            cpuTemperature: SMCReader()?.cpuTemperature(),
            gpuName: GPUReader.readSnapshot().devices.first?.name,
            fanServiceHealth: model.fanServiceHealth
        )
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var notifications: NotificationManager
    let onFinish: () -> Void

    @State private var step: Int
    @State private var probe = SetupProbe(liquidctlPath: nil, cpuTemperature: nil,
                                          gpuName: nil, fanServiceHealth: .notInstalled)
    @State private var copiedBrew = false
    @State private var showInstaller = false

    private let stepCount = 4

    init(model: AppModel, notifications: NotificationManager, startAt: Int? = nil,
         onFinish: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        _notifications = ObservedObject(wrappedValue: notifications)
        self.onFinish = onFinish
        _step = State(initialValue: startAt ?? Self.initialStep)
    }

    private static var initialStep: Int {
        let argument = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--step=") }
        guard let argument, let value = Int(argument.dropFirst(7)) else { return 0 }
        return min(3, max(0, value))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case 0: welcome
                    case 1: environment
                    case 2: permissions
                    default: ready
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .frame(width: 620, height: 500)
        .background(Theme.canvas)
        .tint(Theme.accent)
        .onAppear(perform: refreshProbe)
        .onChange(of: notifications.authorizationStatus) { _ in
            refreshProbe()
        }
        .onChange(of: model.fanServiceHealth) { _ in
            refreshProbe()
        }
        .sheet(isPresented: $showInstaller) {
            FanServiceInstallerSheet(model: model)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("LiquidBar")
                .font(Typography.wordmark(14))
                .foregroundStyle(Theme.ink)
            Text(L10n.text("setupAssistant"))
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryInk)
            Spacer()
            HStack(spacing: 5) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Theme.accent : Theme.border)
                        .frame(width: index == step ? 16 : 6, height: 6)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Theme.surfaceMuted)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                appIcon(size: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("onboardingWelcomeTitle"))
                        .font(Typography.display(26))
                        .foregroundStyle(Theme.ink)
                    Text(L10n.text("onboardingWelcomeBody"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                feature("thermometer.medium", L10n.text("featureMonitor"))
                feature("fanblades", L10n.text("featureControl"))
                feature("lightbulb", L10n.text("featureLighting"))
                feature("menubar.rectangle", L10n.text("featureMenuBar"))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )

            EmptyHint(text: L10n.text("onboardingWelcomeHint"))
        }
    }

    private var environment: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("onboardingEnvironmentTitle"))
                .font(Typography.display(24))
                .foregroundStyle(Theme.ink)
            Text(L10n.text("onboardingEnvironmentBody"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryInk)

            VStack(spacing: 0) {
                checkRow(
                    symbol: "shippingbox",
                    title: "liquidctl",
                    detail: probe.liquidctlPath ?? L10n.text("liquidctlMissing"),
                    state: probe.liquidctlPath == nil ? .denied : .granted
                )
                Hairline()
                checkRow(
                    symbol: "cpu",
                    title: L10n.text("cpuSensor"),
                    detail: probe.cpuTemperature.map { String(format: "%.1f °C", $0) } ?? L10n.text("cpuSensorMissing"),
                    state: probe.cpuTemperature == nil ? .denied : .granted
                )
                Hairline()
                checkRow(
                    symbol: "rectangle.on.rectangle",
                    title: "GPU",
                    detail: probe.gpuName ?? L10n.text("gpuMissing"),
                    state: probe.gpuName == nil ? .optional : .granted
                )
                Hairline()
                checkRow(
                    symbol: "fanblades",
                    title: L10n.text("coolingDevices"),
                    detail: deviceDetail,
                    state: liveDeviceRoles.isEmpty ? .optional : .granted
                )
                Hairline()
                checkRow(
                    symbol: "lock.shield",
                    title: L10n.text("fanService"),
                    detail: fanServiceDetail,
                    state: fanServiceState
                )
            }
            .cardSurface(padding: 0)

            if probe.fanServiceHealth == .needsRestart {
                HStack(spacing: 8) {
                    Button(L10n.text("restartApp")) { model.restartApplication() }
                        .buttonStyle(ClaudePrimaryButtonStyle())
                    Spacer()
                }
            } else if probe.fanServiceHealth == .needsUpdate {
                HStack(spacing: 8) {
                    Button(L10n.text("updateFanService")) { showInstaller = true }
                        .buttonStyle(ClaudePrimaryButtonStyle())
                    Spacer()
                }
            }

            if probe.liquidctlPath == nil {
                HStack(spacing: 8) {
                    Text("brew install liquidctl")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.secondaryInk)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Button(copiedBrew ? L10n.text("copied") : L10n.text("copyCommand")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install liquidctl", forType: .string)
                        copiedBrew = true
                    }
                    .buttonStyle(ClaudeSecondaryButtonStyle())
                    Button(L10n.text("recheck"), action: refreshProbe)
                        .buttonStyle(ClaudeQuietButtonStyle())
                }
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("onboardingPermissionsTitle"))
                .font(Typography.display(24))
                .foregroundStyle(Theme.ink)
            Text(L10n.text("onboardingPermissionsBody"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            SettingsCard(title: L10n.text("permissionNotificationsTitle"), subtitle: L10n.text("permissionNotificationsBody")) {
                HStack(spacing: 10) {
                    Image(systemName: notificationIcon)
                        .font(.system(size: 14))
                        .foregroundStyle(notificationColor)
                    Text(notificationStatusText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    if notifications.authorizationStatus == .notDetermined {
                        Button(L10n.text("allow")) {
                            model.updateNotifications(enabled: true)
                        }
                        .buttonStyle(ClaudePrimaryButtonStyle())
                    } else if notifications.authorizationStatus == .denied {
                        Button(L10n.text("openNotificationSettings"), action: model.openNotificationSettings)
                            .buttonStyle(ClaudeSecondaryButtonStyle())
                    }
                }
            }

            SettingsCard(title: L10n.text("permissionLoginTitle"), subtitle: L10n.text("permissionLoginBody")) {
                HStack(spacing: 10) {
                    Image(systemName: loginIcon)
                        .font(.system(size: 14))
                        .foregroundStyle(loginColor)
                    Text(loginStatusText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Toggle("", isOn: launchBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if model.loginItemStatus == .requiresApproval {
                    HStack(spacing: 8) {
                        Text(L10n.text("loginNeedsApproval"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warm)
                        Button(L10n.text("openLoginItems"), action: model.openLoginItemsSettings)
                            .buttonStyle(ClaudeSecondaryButtonStyle())
                    }
                }
            }

            EmptyHint(text: L10n.text("permissionMoreLater"))
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                appIcon(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("onboardingReadyTitle"))
                        .font(Typography.display(24))
                        .foregroundStyle(Theme.ink)
                    Text(L10n.text("onboardingReadyBody"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryInk)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                summaryRow("checkmark.circle.fill", L10n.text("summaryMenuBar"), Theme.cool)
                summaryRow("checkmark.circle.fill", L10n.text("summaryMonitoring"), Theme.cool)
                summaryRow(fanServiceSummary.0, fanServiceSummary.1, fanServiceSummary.2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )

            EmptyHint(text: L10n.text("onboardingReadyHint"))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if step > 0 {
                Button(L10n.text("back")) { step -= 1 }
                    .buttonStyle(ClaudeSecondaryButtonStyle())
            }
            Spacer()
            if step < stepCount - 1 {
                Button(L10n.text("continue")) { step += 1 }
                    .buttonStyle(ClaudePrimaryButtonStyle())
            } else {
                Button(L10n.text("finish")) { finish() }
                    .buttonStyle(ClaudePrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Theme.surfaceMuted)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func checkRow(symbol: String, title: String, detail: String, state: PermissionState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryInk)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(2)
            }
            Spacer(minLength: 10)
            Image(systemName: state == .granted ? "checkmark.circle.fill"
                  : state == .denied ? "exclamationmark.circle.fill" : "circle.dashed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(state == .granted ? Theme.cool : state == .denied ? Theme.warm : Theme.tertiaryInk)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func summaryRow(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func appIcon(size: CGFloat) -> some View {
        Group {
            if let image = NSImage(named: "AppIcon") {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "fanblades.fill")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.accentSoft)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }

    private var fanServiceDetail: String {
        switch probe.fanServiceHealth {
        case .installed: return L10n.text("installed")
        case .needsUpdate: return L10n.text("fanServiceUpdateShort")
        case .needsRestart: return L10n.text("fanServiceRestartShort")
        case .notInstalled: return L10n.text("fanServiceOptional")
        }
    }

    private var fanServiceState: PermissionState {
        switch probe.fanServiceHealth {
        case .installed: return .granted
        case .needsUpdate, .needsRestart: return .denied
        case .notInstalled: return .optional
        }
    }

    private var fanServiceSummary: (String, String, Color) {
        switch probe.fanServiceHealth {
        case .installed: return ("checkmark.circle.fill", L10n.text("summaryFanServiceInstalled"), Theme.cool)
        case .needsUpdate: return ("exclamationmark.circle.fill", L10n.text("summaryFanServiceUpdate"), Theme.warm)
        case .needsRestart: return ("exclamationmark.circle.fill", L10n.text("summaryFanServiceRestart"), Theme.warm)
        case .notInstalled: return ("circle.dashed", L10n.text("summaryFanServiceLater"), Theme.tertiaryInk)
        }
    }

    private var liveDeviceRoles: [String] {
        model.snapshot.visibleDeviceRoles
    }

    private var deviceDetail: String {
        guard !liveDeviceRoles.isEmpty else {
            return model.snapshot.connected ? L10n.text("noDevicesHint") : L10n.text("detectingDevices")
        }
        return liveDeviceRoles.map { role in
            switch role {
            case "smart": return "NZXT Smart Device V2"
            case "aura": return "ASUS AURA"
            case "ld": return "DeepCool LD-Series"
            default: return "NZXT Kraken"
            }
        }.joined(separator: " · ")
    }

    private var notificationIcon: String {
        switch notifications.authorizationStatus {
        case .authorized: return "checkmark.circle.fill"
        case .denied: return "exclamationmark.circle.fill"
        default: return "bell"
        }
    }

    private var notificationColor: Color {
        switch notifications.authorizationStatus {
        case .authorized: return Theme.cool
        case .denied: return Theme.warm
        default: return Theme.secondaryInk
        }
    }

    private var notificationStatusText: String {
        switch notifications.authorizationStatus {
        case .authorized: return L10n.text("allowed")
        case .denied: return L10n.text("denied")
        case .notDetermined: return L10n.text("notRequested")
        default: return L10n.text("unknown")
        }
    }

    private var loginIcon: String {
        model.loginItemStatus == .enabled ? "checkmark.circle.fill" : "power"
    }

    private var loginColor: Color {
        model.loginItemStatus == .enabled ? Theme.cool : Theme.secondaryInk
    }

    private var loginStatusText: String {
        switch model.loginItemStatus {
        case .enabled: return L10n.text("enabled")
        case .requiresApproval: return L10n.text("requiresApproval")
        case .notRegistered: return L10n.text("disabled")
        default: return L10n.text("unknown")
        }
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { model.loginItemStatus == .enabled || model.loginItemStatus == .requiresApproval },
            set: { model.updateLaunchAtLogin(enabled: $0) }
        )
    }

    private func refreshProbe() {
        probe = SetupProbe.run(using: model)
    }

    private func finish() {
        model.settingsStore.value.setupCompleted = true
        onFinish()
    }
}
