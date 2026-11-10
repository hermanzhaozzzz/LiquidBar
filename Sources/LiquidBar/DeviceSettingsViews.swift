import SwiftUI

struct DeviceControlsSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore

    var body: some View {
        GroupBox(L10n.text("devices")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.snapshot.visibleDeviceRoles, id: \.self) { role in
                    HStack {
                        Circle().fill(model.snapshot.devices[role]?.connected == true ? Color.green : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(deviceName(role))
                        Spacer()
                        Text(model.snapshot.devices[role]?.connected == true ? L10n.text("connected") : L10n.text("notPresent"))
                            .foregroundStyle(.secondary)
                    }
                    if let error = model.snapshot.devices[role]?.error {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
                if let error = model.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
                Button(L10n.text("refresh"), action: model.refreshNow)
            }.padding(6)
        }
        if model.snapshot.hasSmart {
            GroupBox(L10n.text("fanCurve")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(L10n.text("curveEnable"), isOn: Binding(
                        get: { store.value.fanCurve?.enabled == true },
                        set: model.setCurveEnabled
                    ))
                    Stepper("\(L10n.text("curveCool")) \(Int(curve.wrappedValue.coolTemperature))°C", value: curve.coolTemperature, in: 25...75)
                    Stepper("\(L10n.text("curveHot")) \(Int(curve.wrappedValue.hotTemperature))°C", value: curve.hotTemperature, in: 30...90)
                    Stepper("\(L10n.text("minimum")) \(curve.wrappedValue.minimumDuty)%", value: curve.minimumDuty, in: 30...100)
                    Stepper("\(L10n.text("maximum")) \(curve.wrappedValue.maximumDuty)%", value: curve.maximumDuty, in: 30...100)
                    Text(L10n.text("curveHelp")).font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }
        }
        if model.snapshot.supports("smart", "lighting") {
            LightingEditor(model: model, role: "smart", title: L10n.text("caseLighting"), channels: ["led1", "led2", "sync"], initial: store.value.lighting?["smart"] ?? LightingSettings(channel: "led1"))
        }
        if model.snapshot.supports("aura", "lighting") {
            LightingEditor(model: model, role: "aura", title: L10n.text("coolerLighting"), channels: ["led2", "sync"], initial: store.value.lighting?["aura"] ?? LightingSettings(channel: "led2"))
        }
        if model.snapshot.supports("ld", "display") {
            GroupBox("DeepCool LD — " + L10n.text("display")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(L10n.text("displayEnable"), isOn: Binding(
                        get: { store.value.display?.enabled == true }, set: model.setDisplayEnabled
                    ))
                    Picker(L10n.text("temperatureUnit"), selection: Binding(
                        get: { store.value.display?.unit ?? "C" },
                        set: { unit in
                            var value = store.value.display ?? DisplaySettings()
                            value.unit = unit
                            store.value.display = value
                        }
                    )) {
                        Text("°C").tag("C")
                        Text("°F").tag("F")
                    }.pickerStyle(.segmented).frame(width: 150)
                    Text(L10n.text("displayHelp")).font(.caption).foregroundStyle(.secondary)
                    if let lastSent = model.displayLastSent {
                        Text("\(L10n.text("lastSent")): \(lastSent.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.displayError { Text(error).font(.caption).foregroundStyle(.orange) }
                }.padding(6)
            }
        }
        MotherboardControlsView(model: model, store: store)
    }

    private var curve: Binding<FanCurveSettings> {
        Binding(get: { store.value.fanCurve ?? FanCurveSettings() }, set: { store.value.fanCurve = $0 })
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

private struct LightingEditor: View {
    @ObservedObject var model: AppModel
    let role: String
    let title: String
    let channels: [String]
    @State private var settings: LightingSettings

    init(model: AppModel, role: String, title: String, channels: [String], initial: LightingSettings) {
        self.model = model
        self.role = role
        self.title = title
        self.channels = channels
        _settings = State(initialValue: initial)
    }

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 10) {
                if channels.count > 1 {
                    Picker(L10n.text("channel"), selection: $settings.channel) {
                        ForEach(channels, id: \.self) { channel in
                            Text(role == "aura" && channel == "led2" ? "ARGB 1" : channel == "led1" ? "RGB 1 — " + L10n.text("caseStrips") : channel == "led2" ? "RGB 2" : L10n.text("allChannels")).tag(channel)
                        }
                    }
                }
                Picker(L10n.text("effect"), selection: $settings.mode) {
                    ForEach(["fixed", "off", "breathing", "rainbow"], id: \.self) { mode in
                        Text(L10n.text(mode)).tag(mode)
                    }
                }
                ColorPicker(L10n.text("color"), selection: color, supportsOpacity: false)
                    .disabled(settings.mode == "off" || settings.mode == "rainbow")
                HStack {
                    Text(L10n.text("brightness"))
                    Slider(value: $settings.brightness, in: 0...1)
                    Text("\(Int(settings.brightness * 100))%")
                }.disabled(settings.mode == "off" || settings.mode == "rainbow")
                Text(role == "smart" ? L10n.text("nzxtLightingHelp") : L10n.text("auraLightingHelp"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("apply")) { model.applyLighting(role, settings: settings) }
                    .disabled(model.busy || !model.snapshot.supports(role, "lighting"))
            }.padding(6)
        }
    }

    private var color: Binding<Color> {
        Binding(get: { Color(red: settings.red, green: settings.green, blue: settings.blue) }, set: {
            guard let rgb = NSColor($0).usingColorSpace(.deviceRGB) else { return }
            settings.red = rgb.redComponent
            settings.green = rgb.greenComponent
            settings.blue = rgb.blueComponent
        })
    }
}

private struct MotherboardControlsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore

    var body: some View {
        GroupBox(L10n.text("fanService")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text(model.persistentFanServiceInstalled ? "fanServiceInstalled" : "fanServiceInstallHelp"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("refresh"), action: model.initializeMotherboard)
                    .disabled(model.motherboardBusy)
                if !model.persistentFanServiceInstalled {
                    Toggle(L10n.text("temporaryFanSession"), isOn: Binding(
                        get: { store.value.temporaryMotherboardControl == true },
                        set: { enabled in Task { await model.setTemporaryMotherboardControl(enabled) } }
                    )).disabled(model.motherboardBusy)
                    Text(L10n.text("temporaryFanSessionHelp")).font(.caption).foregroundStyle(.secondary)
                }
                if let reason = model.radiatorControlReason { Text(reason).font(.caption) }
                if !model.usesTemporaryMotherboardControl, let error = model.motherboardError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }.padding(6)
        }
        if model.usesTemporaryMotherboardControl {
        GroupBox(L10n.text("motherboardFans")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("motherboardHelp")).font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("detectMotherboard"), action: model.initializeMotherboard)
                    .disabled(model.motherboardBusy)
                if let snapshot = model.motherboardSnapshot {
                    Text("\(snapshot.driverVersion) · \(snapshot.chipID.map { String(format: "0x%04llX", $0) } ?? "--")")
                        .font(.caption.monospaced())
                    ForEach(snapshot.fans) { fan in
                        HStack {
                            Text("#\(fan.index) \(fan.name)")
                            Spacer()
                            Text("\(fan.rpm) RPM · \(fan.duty)% · \(fan.automatic ? L10n.text("automatic") : L10n.text("manual"))")
                        }.font(.caption.monospacedDigit())
                    }
                    mappingPicker("CPU_FAN", index: mapping.cpuIndex, fans: snapshot.fans)
                    mappingPicker("AIO_PUMP", index: mapping.pumpIndex, fans: snapshot.fans)
                    HStack {
                        Button("CPU_FAN " + L10n.text("testIncrease")) { model.testMotherboard(.cpu) }
                            .disabled(model.motherboardBusy || mapping.wrappedValue.cpuIndex == nil)
                        Button("AIO_PUMP " + L10n.text("testIncrease")) { model.testMotherboard(.pump) }
                            .disabled(model.motherboardBusy || mapping.wrappedValue.pumpIndex == nil)
                    }
                    if let result = model.motherboardTestResult { Text(result).font(.caption.monospaced()) }
                    Toggle(L10n.text("cpuMappingConfirmed"), isOn: Binding(
                        get: { model.radiatorMappingConfirmed }, set: model.confirmRadiatorMapping
                    ))
                        .disabled(model.motherboardBusy || mapping.wrappedValue.cpuIndex == nil ||
                                  mapping.wrappedValue.cpuIndex == mapping.wrappedValue.pumpIndex)
                    Toggle(L10n.text("mappingConfirmed"), isOn: mapping.confirmed)
                    if mapping.wrappedValue.cpuIndex == mapping.wrappedValue.pumpIndex && mapping.wrappedValue.cpuIndex != nil {
                        Text(L10n.text("mappingConflict")).font(.caption).foregroundStyle(.orange)
                    }
                    motherboardSlider(role: .cpu, title: "CPU_FAN", value: $model.motherboardCPUTarget, minimum: 30)
                    motherboardSlider(role: .pump, title: "AIO_PUMP", value: $model.motherboardPumpTarget, minimum: 80)
                    Button(L10n.text("restoreBIOS"), action: model.restoreMotherboard)
                        .disabled(model.motherboardBusy)
                }
                if let error = model.motherboardError { Text(error).font(.caption).foregroundStyle(.orange) }
            }.padding(6)
        }
        }
    }

    private var mapping: Binding<MotherboardMappingSettings> {
        Binding(get: { store.value.motherboardMapping ?? MotherboardMappingSettings() }, set: { store.value.motherboardMapping = $0 })
    }

    private func mappingPicker(_ label: String, index: Binding<Int?>, fans: [MotherboardFanReading]) -> some View {
        Picker(label, selection: Binding(get: { index.wrappedValue ?? -1 }, set: {
            index.wrappedValue = $0 < 0 ? nil : $0
            store.value.motherboardMapping?.confirmed = false
            store.value.motherboardMapping?.confirmedCPUIndex = nil
        })) {
            Text(L10n.text("unmapped")).tag(-1)
            ForEach(fans) { fan in Text("#\(fan.index) \(fan.name)").tag(fan.index) }
        }
    }

    private func motherboardSlider(role: MotherboardFanRole, title: String, value: Binding<Double>, minimum: Double) -> some View {
        let valid = mapping.wrappedValue.confirmedIndex(for: role) != nil && !model.motherboardBusy
        return HStack {
            Text("\(title) \(L10n.text("target")) \(Int(value.wrappedValue))%")
            Slider(value: value, in: minimum...100, step: 1)
            Button(L10n.text("apply")) { Task { await model.applyMotherboard(role) } }
        }.disabled(!valid)
    }
}
