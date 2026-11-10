import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case cooling
    case lighting
    case motherboard
    case alerts
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.text("paneGeneral")
        case .cooling: return L10n.text("paneCooling")
        case .lighting: return L10n.text("paneLighting")
        case .motherboard: return L10n.text("paneMotherboard")
        case .alerts: return L10n.text("paneAlerts")
        case .diagnostics: return L10n.text("paneDiagnostics")
        }
    }

    static var initial: SettingsPane {
        let argument = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--pane=") }
        guard let argument, let pane = SettingsPane(rawValue: String(argument.dropFirst(7))) else {
            return .general
        }
        return pane
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .cooling: return "fanblades"
        case .lighting: return "lightbulb"
        case .motherboard: return "cpu"
        case .alerts: return "bell"
        case .diagnostics: return "stethoscope"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var pane: SettingsPane
    init(pane: SettingsPane = .initial) { self.pane = pane }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var notifications: NotificationManager
    @ObservedObject var navigation: SettingsNavigation
    var showOnboarding: () -> Void = {}

    private var pane: SettingsPane { navigation.pane }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.border).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    pageHeader
                    switch pane {
                    case .general: GeneralSettingsView(model: model, store: store)
                    case .cooling: CoolingSettingsView(model: model, store: store)
                    case .lighting: LightingSettingsView(model: model, store: store)
                    case .motherboard: MotherboardSettingsView(model: model, store: store)
                    case .alerts: AlertsSettingsView(model: model, store: store, notifications: notifications)
                    case .diagnostics: DiagnosticsSettingsView(model: model)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.canvas)
        }
        .frame(width: 780, height: 580)
        .background(Theme.canvas)
        .tint(Theme.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                appIcon
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("LiquidBar")
                        .font(Typography.wordmark(14))
                        .foregroundStyle(Theme.ink)
                    Text(AppVersion.current)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryInk)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            VStack(spacing: 2) {
                ForEach(SettingsPane.allCases) { item in
                    Button {
                        navigation.pane = item
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 15)
                            Text(item.title)
                                .font(.system(size: 12, weight: pane == item ? .semibold : .regular))
                            Spacer()
                        }
                        .foregroundStyle(pane == item ? Theme.accent : Theme.secondaryInk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            pane == item ? Theme.accentSoft : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 12)

            Button(action: showOnboarding) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 10))
                    Text(L10n.text("setupAssistant"))
                        .font(.system(size: 11))
                    Spacer()
                }
                .foregroundStyle(Theme.secondaryInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .frame(width: 206)
        .background(Theme.surfaceMuted)
    }

    private var appIcon: some View {
        Group {
            if let image = NSImage(named: "AppIcon") {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(pane.title)
                .font(Typography.display(24))
                .foregroundStyle(Theme.ink)
            Text(pageSubtitle)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryInk)
        }
        .padding(.bottom, 2)
    }

    private var pageSubtitle: String {
        switch pane {
        case .general: return L10n.text("generalSubtitle")
        case .cooling: return L10n.text("coolingSubtitle")
        case .lighting: return L10n.text("lightingSubtitle")
        case .motherboard: return L10n.text("motherboardSubtitle")
        case .alerts: return L10n.text("alertsSubtitle")
        case .diagnostics: return L10n.text("diagnosticsSubtitle")
        }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsCard(title: L10n.text("startup"), subtitle: L10n.text("startupHelp")) {
            SettingRow(title: L10n.text("launchAtLogin")) {
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

        SettingsCard(title: L10n.text("sampling"), subtitle: L10n.text("samplingHelp")) {
            SteppedLever(
                options: SamplingProfile.allCases.map { (value: $0, label: $0.label) },
                selection: samplingBinding
            )
            .frame(maxWidth: 320)
            Text(samplingDetail)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }

        SettingsCard(title: L10n.text("menuBarTemperature"), subtitle: L10n.text("menuBarHelp")) {
            Picker(L10n.text("menuBarTemperature"), selection: menuBarTemperatureDisplayBinding) {
                Text("CPU").tag(MenuBarTemperatureDisplay.cpu)
                Text("GPU").tag(MenuBarTemperatureDisplay.gpu)
                Text("CPU + GPU").tag(MenuBarTemperatureDisplay.cpuAndGPU)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            HStack(spacing: 12) {
                ForEach(model.menuBarItems) { item in
                    HStack(spacing: 4) {
                        if let image = MenuBarTemperatureRenderer.image(for: item) {
                            Image(nsImage: image)
                        }
                        Text(item.formattedTemperature).monospacedDigit()
                    }
                    .foregroundStyle(Color(nsColor: MenuBarTemperatureRenderer.color(for: item.level)))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.accessibilityText)
                }
                Spacer()
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if model.snapshot.hasLiquidSensor {
                SettingRow(title: L10n.text("showLiquidTemperatureInMenuBar")) {
                    Toggle("", isOn: showLiquidTemperatureInMenuBarBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
    }

    private var samplingBinding: Binding<SamplingProfile> {
        Binding(
            get: { store.value.samplingProfile ?? .balanced },
            set: { store.value.samplingProfile = $0 }
        )
    }

    private var samplingDetail: String {
        let profile = store.value.samplingProfile ?? .balanced
        return String(
            format: L10n.text("samplingDetailFormat"),
            Int32(profile.telemetryInterval),
            Int32(profile.deviceInterval(popoverOpen: true)),
            Int32(profile.deviceInterval(popoverOpen: false))
        )
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { model.loginItemStatus == .enabled || model.loginItemStatus == .requiresApproval },
            set: { model.updateLaunchAtLogin(enabled: $0) }
        )
    }

    private var showLiquidTemperatureInMenuBarBinding: Binding<Bool> {
        Binding(
            get: { store.value.showLiquidTemperatureInMenuBar == true },
            set: { store.value.showLiquidTemperatureInMenuBar = $0 }
        )
    }

    private var menuBarTemperatureDisplayBinding: Binding<MenuBarTemperatureDisplay> {
        Binding(
            get: { store.value.menuBarTemperatureDisplay ?? .cpu },
            set: { store.value.menuBarTemperatureDisplay = $0 }
        )
    }
}

enum PermissionState {
    case granted, denied, optional
}

struct CoolingSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore

    var body: some View {
        if model.snapshot.hasSmart {
            SettingsCard(title: L10n.text("fanCurve"), subtitle: L10n.text("curveHelp")) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                    GridRow {
                        Text(L10n.text("curveCool"))
                        Stepper("\(Int(curve.wrappedValue.coolTemperature))°C", value: curve.coolTemperature, in: 25...75)
                    }
                    GridRow {
                        Text(L10n.text("curveHot"))
                        Stepper("\(Int(curve.wrappedValue.hotTemperature))°C", value: curve.hotTemperature, in: 30...90)
                    }
                    GridRow {
                        Text(L10n.text("minimum"))
                        Stepper("\(curve.wrappedValue.minimumDuty)%", value: curve.minimumDuty, in: 30...100)
                    }
                    GridRow {
                        Text(L10n.text("maximum"))
                        Stepper("\(curve.wrappedValue.maximumDuty)%", value: curve.maximumDuty, in: 30...100)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
            }
        }

        if model.snapshot.hasSmart || model.showRadiatorControl {
            SettingsCard(title: L10n.text("presets"), subtitle: L10n.text("presetsHelp")) {
                VStack(spacing: 9) {
                    ForEach(PresetID.allCases) { id in
                        PresetEditor(
                            id: id,
                            preset: presetBinding(id),
                            showFan: model.snapshot.hasSmart,
                            showRadiator: model.showRadiatorControl && model.radiatorMappingConfirmed
                        )
                    }
                }
            }
        }

        if model.snapshot.hasSmart {
            SettingsCard(title: L10n.text("fanNames"), subtitle: L10n.text("fanNamesHelp")) {
                VStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
                        HStack(spacing: 8) {
                            Text("F\(index + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.tertiaryInk)
                                .frame(width: 18, alignment: .leading)
                            TextField("Fan \(index + 1)", text: fanNameBinding(index))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Button(L10n.text("identify")) { model.identifyFan(index) }
                                .buttonStyle(ClaudeSecondaryButtonStyle())
                                .disabled(model.busy)
                        }
                    }
                }
            }
        }

        if !model.snapshot.hasCoolingControl {
            SettingsCard(title: L10n.text("cooling")) {
                EmptyHint(text: L10n.text("smartDisconnected"))
            }
        }
    }

    private var curve: Binding<FanCurveSettings> {
        Binding(get: { store.value.fanCurve ?? FanCurveSettings() }, set: { store.value.fanCurve = $0 })
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
}

private struct PresetEditor: View {
    let id: PresetID
    @Binding var preset: CoolingPreset
    let showFan: Bool
    let showRadiator: Bool

    private var stepperWidth: CGFloat { showRadiator ? 112 : 128 }

    var body: some View {
        HStack(spacing: 10) {
            Text(L10n.preset(id))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(width: 62, alignment: .leading)
            Spacer(minLength: 6)
            if showFan {
                Stepper("\(L10n.text("fan")) \(preset.fanDuty)%", value: $preset.fanDuty, in: 30...100)
                    .frame(width: stepperWidth)
            }
            if showRadiator {
                Stepper(
                    "\(L10n.text("radiatorShort")) \(preset.radiatorDuty ?? 55)%",
                    value: Binding(
                        get: { preset.radiatorDuty ?? 55 },
                        set: { preset.radiatorDuty = $0 }
                    ),
                    in: 30...100
                )
                .frame(width: stepperWidth)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.surfaceMuted.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct LightingSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore

    @State private var role = "smart"
    @State private var settings = LightingSettings()
    @State private var lastApplied: LightingSettings?
    @State private var applyTask: Task<Void, Never>?

    private var roles: [String] {
        var result: [String] = []
        if model.snapshot.supports("smart", "lighting") { result.append("smart") }
        if model.snapshot.supports("aura", "lighting") { result.append("aura") }
        return result
    }

    var body: some View {
        if roles.isEmpty {
            if model.snapshot.supports("ld", "display") {
                DisplayEditor(store: store, model: model)
            } else {
                SettingsCard(title: L10n.text("lightingControl")) {
                    EmptyHint(text: L10n.text("noLightingDevices"))
                }
            }
        } else {
            lightingCard
            if model.snapshot.supports("ld", "display") {
                DisplayEditor(store: store, model: model)
            }
        }
    }

    private var lightingCard: some View {
        SettingsCard(
            title: L10n.text("lightingControl"),
            subtitle: role == "smart" ? L10n.text("nzxtLightingHelp") : L10n.text("auraLightingHelp")
        ) {
            if roles.count > 1 {
                SteppedLever(
                    options: roles.map { (value: $0, label: $0 == "smart" ? "NZXT" : "ASUS AURA") },
                    selection: roleBinding
                )
                .frame(maxWidth: 320)
            }
            if channels(for: role).count > 1 {
                SteppedLever(
                    options: channels(for: role).map { (value: $0, label: channelName($0)) },
                    selection: channelBinding
                )
                .frame(maxWidth: 320)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("effect"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
                HStack(spacing: 6) {
                    ForEach(effects, id: \.0) { mode, title, symbol in
                        EffectChip(title: title, symbol: symbol, selected: settings.mode == mode) {
                            settings.mode = mode
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("color"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
                HStack(spacing: 8) {
                    ForEach(Array(LightingPalette.colors.enumerated()), id: \.offset) { _, color in
                        ColorSwatch(color: color, selected: LightingPalette.matches(settings, color)) {
                            setColor(color)
                        }
                    }
                    ColorPicker("", selection: colorBinding, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 28)
                        .help(L10n.text("customColor"))
                    Text(L10n.text("customColor"))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiaryInk)
                    Spacer()
                }
                .opacity(settings.mode == "off" || settings.mode == "rainbow" ? 0.35 : 1)
                .disabled(settings.mode == "off" || settings.mode == "rainbow")
            }

            HStack(spacing: 8) {
                Text(L10n.text("brightness"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(width: 52, alignment: .leading)
                Slider(value: $settings.brightness, in: 0...1)
                    .tint(Theme.accent)
                Text("\(Int(settings.brightness * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(width: 34, alignment: .trailing)
            }
            .opacity(settings.mode == "off" || settings.mode == "rainbow" ? 0.35 : 1)
            .disabled(settings.mode == "off" || settings.mode == "rainbow")

            HStack(spacing: 6) {
                if model.busy {
                    ProgressView().controlSize(.mini)
                    Text(L10n.text("applying"))
                } else {
                    Text(L10n.text("autoApplyHint"))
                }
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.tertiaryInk)

            if !roles.isEmpty {
                Hairline()
                SettingRow(title: L10n.text("showLightingInPanel"), detail: L10n.text("showLightingInPanelHelp")) {
                    Toggle("", isOn: Binding(
                        get: { store.value.showLightingInPanel == true },
                        set: { store.value.showLightingInPanel = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
        }
        .onAppear(perform: load)
        .onDisappear { applyTask?.cancel() }
        .onChange(of: role) { _ in load() }
        .onChange(of: roles) { _ in if !roles.contains(role) { load() } }
        .onChange(of: settings) { _ in scheduleApply() }
    }

    private var roleBinding: Binding<String> {
        Binding(get: { role }, set: { role = $0 })
    }

    private var channelBinding: Binding<String> {
        Binding(get: { settings.channel }, set: { settings.channel = $0 })
    }

    private func channels(for role: String) -> [String] {
        let real = role == "aura" ? ["led2"] : ["led1", "led2"]
        return real.count > 1 ? real + ["sync"] : real
    }

    private func channelName(_ channel: String) -> String {
        if role == "aura" && channel == "led2" { return "ARGB 1" }
        switch channel {
        case "led1": return "RGB 1"
        case "led2": return "RGB 2"
        default: return L10n.text("allChannels")
        }
    }

    private var effects: [(String, String, String)] {
        [
            ("fixed", L10n.text("fixed"), "circle.fill"),
            ("off", L10n.text("off"), "power"),
            ("breathing", L10n.text("breathing"), "wind"),
            ("rainbow", L10n.text("rainbow"), "rainbow"),
        ]
    }


    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(red: settings.red, green: settings.green, blue: settings.blue) },
            set: { setColor($0) }
        )
    }

    private func setColor(_ color: Color) {
        LightingPalette.apply(color, to: &settings)
    }

    private func load() {
        applyTask?.cancel()
        applyTask = nil
        guard roles.contains(role) else {
            role = roles.first ?? "smart"
            return
        }
        var value = store.value.lighting?[role]
            ?? LightingSettings(channel: role == "aura" ? "led2" : "led1")
        let available = channels(for: role)
        if !available.contains(value.channel) { value.channel = available.first ?? "sync" }
        settings = value
        lastApplied = value
    }

    private func scheduleApply() {
        guard settings != lastApplied else { return }
        applyTask?.cancel()
        let snapshot = settings
        let targetRole = role
        applyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, role == targetRole else { return }
            var waits = 0
            while model.busy && waits < 30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waits += 1
            }
            guard !Task.isCancelled, role == targetRole else { return }
            model.applyLighting(targetRole, settings: snapshot)
            lastApplied = snapshot
        }
    }
}



private struct DisplayEditor: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsCard(title: "DeepCool LD — " + L10n.text("display"), subtitle: L10n.text("displayHelp")) {
            SettingRow(title: L10n.text("displayEnable")) {
                Toggle("", isOn: Binding(
                    get: { store.value.display?.enabled == true },
                    set: model.setDisplayEnabled
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            SettingRow(title: L10n.text("temperatureUnit")) {
                Picker("", selection: Binding(
                    get: { store.value.display?.unit ?? "C" },
                    set: { unit in
                        var value = store.value.display ?? DisplaySettings()
                        value.unit = unit
                        store.value.display = value
                    }
                )) {
                    Text("°C").tag("C")
                    Text("°F").tag("F")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }
            if let lastSent = model.displayLastSent {
                Text("\(L10n.text("lastSent")): \(lastSent.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryInk)
            }
            if let error = model.displayError {
                Text(error).font(.system(size: 10)).foregroundStyle(Theme.warm)
            }
        }
    }
}

struct AlertsSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var notifications: NotificationManager

    var body: some View {
        SettingsCard(title: L10n.text("alerts"), subtitle: L10n.text("alertsHelp")) {
            SettingRow(title: L10n.text("systemNotifications")) {
                Toggle("", isOn: notificationBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingRow(title: L10n.text("criticalSound")) {
                Toggle("", isOn: setting(\.criticalSoundEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!store.value.notificationsEnabled)
            }
            if model.snapshot.hasCoolingControl {
                SettingRow(title: L10n.text("automaticBoost"), detail: L10n.text("automaticBoostHelp")) {
                    Toggle("", isOn: setting(\.automaticEmergencyBoost))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
            Hairline()
            Text(L10n.text("thresholds"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
            ThresholdEditor(settings: $store.value.thresholds, showLiquid: model.snapshot.hasLiquidSensor)
            if notifications.authorizationStatus == .denied {
                HStack(spacing: 8) {
                    Text(L10n.text("notificationDenied"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warm)
                    Button(L10n.text("openNotificationSettings"), action: model.openNotificationSettings)
                        .buttonStyle(ClaudeSecondaryButtonStyle())
                }
            }
        }
    }

    private var notificationBinding: Binding<Bool> {
        Binding(
            get: { store.value.notificationsEnabled },
            set: { model.updateNotifications(enabled: $0) }
        )
    }

    private func setting(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.value[keyPath: keyPath] },
            set: { store.value[keyPath: keyPath] = $0 }
        )
    }
}

private struct ThresholdEditor: View {
    @Binding var settings: AlertThresholds
    let showLiquid: Bool

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
            if showLiquid {
                GridRow {
                    Text(L10n.text("liquidWarning"))
                    Stepper("\(Int(settings.liquidWarning))°C", value: $settings.liquidWarning, in: 30...59)
                }
                GridRow {
                    Text(L10n.text("liquidCritical"))
                    Stepper("\(Int(settings.liquidCritical))°C", value: $settings.liquidCritical, in: 35...60)
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.ink)
    }
}

struct DiagnosticsSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsCard(title: L10n.text("devices"), subtitle: L10n.text("devicesHelp")) {
            if model.snapshot.visibleDeviceRoles.isEmpty {
                EmptyHint(text: L10n.text("noDevices"))
            }
            ForEach(model.snapshot.visibleDeviceRoles, id: \.self) { role in
                HStack(spacing: 9) {
                    StatusDot(color: model.snapshot.devices[role]?.connected == true ? Theme.cool : Theme.tertiaryInk)
                    Text(deviceName(role))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(model.snapshot.devices[role]?.connected == true ? L10n.text("connected") : L10n.text("notPresent"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryInk)
                }
                if let error = model.snapshot.devices[role]?.error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.warm)
                        .padding(.leading, 16)
                }
            }
            if let error = model.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(Theme.warm)
            }
            HStack {
                Button(L10n.text("refresh"), action: model.refreshNow)
                    .buttonStyle(ClaudeSecondaryButtonStyle())
                Spacer()
            }
        }

        SettingsCard(title: L10n.text("aboutDiagnostics")) {
            Text(L10n.text("aboutBody"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Hairline()
            HStack(spacing: 8) {
                Button(L10n.text("copyDiagnostics"), action: model.copyDiagnostics)
                    .buttonStyle(ClaudeSecondaryButtonStyle())
                Button(L10n.text("clearLog"), action: model.clearLog)
                    .buttonStyle(ClaudeSecondaryButtonStyle())
                Spacer()
            }
        }
    }

    private func deviceName(_ role: String) -> String {
        switch role {
        case "smart": return "NZXT Smart Device V2"
        case "aura": return "ASUS AURA"
        case "ld": return "DeepCool LD-Series"
        default: return "NZXT Kraken"
        }
    }
}
