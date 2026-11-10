import AppKit
import SwiftUI

struct LightingAllView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore

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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 14)
                Text(L10n.text("allLighting"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 6)
                Toggle("", isOn: powerBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.accent)
            }
            Text(L10n.text("allLightingHelp"))
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiaryInk)
                .fixedSize(horizontal: false, vertical: true)
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
        .onChange(of: settings) { _ in scheduleApply() }
        .onReceive(store.$value) { value in
            let current = roles.compactMap { value.lighting?[$0] }
            guard current.count == roles.count, let first = current.first else { return }
            let same = current.allSatisfy {
                $0.red == first.red && $0.green == first.green && $0.blue == first.blue
                    && $0.mode == first.mode && $0.brightness == first.brightness
            }
            if same, first != settings {
                applyTask?.cancel()
                settings = first
                lastApplied = first
            }
        }
    }

    private var powerBinding: Binding<Bool> {
        Binding(
            get: { settings.mode != "off" },
            set: { on in settings.mode = on ? "fixed" : "off" }
        )
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

    private func load() {
        applyTask?.cancel()
        applyTask = nil
        let first = roles.compactMap { store.value.lighting?[$0] }.first ?? LightingSettings()
        settings = first
        lastApplied = first
    }

    private func scheduleApply() {
        guard settings != lastApplied else { return }
        applyTask?.cancel()
        let snapshot = settings
        applyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            var waits = 0
            while model.busy && waits < 30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waits += 1
            }
            guard !Task.isCancelled else { return }
            var values: [String: LightingSettings] = [:]
            for role in roles {
                var value = store.value.lighting?[role]
                    ?? LightingSettings(channel: role == "aura" ? "led2" : "led1")
                let available = role == "aura" ? ["led2"] : ["led1", "led2", "sync"]
                if !available.contains(value.channel) { value.channel = available.first ?? "sync" }
                value.red = snapshot.red
                value.green = snapshot.green
                value.blue = snapshot.blue
                value.mode = snapshot.mode
                value.brightness = snapshot.brightness
                values[role] = value
            }
            model.applyLightingToAll(values)
            lastApplied = snapshot
        }
    }
}
