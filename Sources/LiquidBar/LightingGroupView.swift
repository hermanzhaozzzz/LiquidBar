import AppKit
import SwiftUI

struct LightingGroupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    let role: String
    let title: String

    @State private var settings = LightingSettings()
    @State private var lastApplied: LightingSettings?
    @State private var applyTask: Task<Void, Never>?

    private var realChannels: [String] {
        role == "aura" ? ["led2"] : ["led1", "led2"]
    }

    private var channels: [String] {
        realChannels.count > 1 ? realChannels + ["sync"] : realChannels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 6)
                Toggle("", isOn: powerBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.accent)
            }
            if channels.count > 1 {
                SteppedLever(options: channels.map { ($0, channelName($0)) }, selection: channelBinding)
            }
            HStack(spacing: 6) {
                ForEach(effects, id: \.0) { mode, label, symbol in
                    EffectChip(title: label, symbol: symbol, selected: settings.mode == mode) {
                        settings.mode = mode
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach(Array(LightingPalette.colors.enumerated()), id: \.offset) { _, color in
                    ColorSwatch(color: color, selected: LightingPalette.matches(settings, color), size: 20) {
                        var value = settings
                        LightingPalette.apply(color, to: &value)
                        value.mode = "fixed"
                        settings = value
                    }
                }
                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 26)
                    .help(L10n.text("customColor"))
                Text(L10n.text("customColor"))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryInk)
                Spacer()
            }
            .opacity(settings.mode == "off" || settings.mode == "rainbow" ? 0.35 : 1)
            .disabled(settings.mode == "off" || settings.mode == "rainbow")
            HStack(spacing: 8) {
                Text(L10n.text("brightness"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(width: 44, alignment: .leading)
                Slider(value: $settings.brightness, in: 0...1)
                    .tint(Theme.accent)
                Text("\(Int(settings.brightness * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(width: 32, alignment: .trailing)
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
            .font(.system(size: 9))
            .foregroundStyle(Theme.tertiaryInk)
        }
        .cardSurface(padding: 11)
        .onAppear(perform: load)
        .onDisappear { applyTask?.cancel() }
        .onChange(of: role) { _ in load() }
        .onChange(of: settings) { _ in scheduleApply() }
        .onReceive(store.$value) { value in
            guard let stored = value.lighting?[role] else { return }
            let normalized = normalized(stored)
            guard normalized != settings else { return }
            applyTask?.cancel()
            settings = normalized
            lastApplied = normalized
        }
    }

    private var powerBinding: Binding<Bool> {
        Binding(
            get: { settings.mode != "off" },
            set: { on in settings.mode = on ? "fixed" : "off" }
        )
    }

    private var channelBinding: Binding<String> {
        Binding(get: { settings.channel }, set: { settings.channel = $0 })
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(red: settings.red, green: settings.green, blue: settings.blue) },
            set: { color in
                var value = settings
                LightingPalette.apply(color, to: &value)
                settings = value
            }
        )
    }

    private var effects: [(String, String, String)] {
        [
            ("fixed", L10n.text("fixed"), "circle.fill"),
            ("off", L10n.text("off"), "power"),
            ("breathing", L10n.text("breathing"), "wind"),
            ("rainbow", L10n.text("rainbow"), "rainbow"),
        ]
    }

    private func channelName(_ channel: String) -> String {
        if role == "aura" && channel == "led2" { return "ARGB 1" }
        switch channel {
        case "led1": return "RGB 1"
        case "led2": return "RGB 2"
        default: return L10n.text("allChannels")
        }
    }

    private func normalized(_ value: LightingSettings) -> LightingSettings {
        var result = value
        if !channels.contains(result.channel) { result.channel = channels.first ?? "sync" }
        return result
    }

    private func load() {
        applyTask?.cancel()
        applyTask = nil
        let value = normalized(
            store.value.lighting?[role] ?? LightingSettings(channel: role == "aura" ? "led2" : "led1")
        )
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
            guard !Task.isCancelled else { return }
            var waits = 0
            while model.busy && waits < 30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waits += 1
            }
            guard !Task.isCancelled else { return }
            model.applyLighting(targetRole, settings: snapshot)
            lastApplied = snapshot
        }
    }
}
