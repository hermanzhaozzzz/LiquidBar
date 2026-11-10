import AppKit
import SwiftUI

struct SensorTile: View {
    let title: String
    let value: String
    var unit: String = "°C"
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.secondaryInk)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(Typography.numeral(19))
                    .foregroundStyle(tint)
                Text(unit)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        )
    }
}

struct TemperatureChart: View {
    let samples: [HistorySample]
    let showsLiquid: Bool
    let showsGPU: Bool

    private struct Series {
        let keyPath: KeyPath<HistorySample, Double?>
        let color: Color
    }

    private var series: [Series] {
        var result = [Series(keyPath: \.cpuTemperature, color: Theme.cpuLine)]
        if showsLiquid { result.append(Series(keyPath: \.liquidTemperature, color: Theme.liquidLine)) }
        if showsGPU { result.append(Series(keyPath: \.gpuTemperature, color: Theme.gpuLine)) }
        return result
    }

    private var limits: ClosedRange<Double> {
        let values = samples.flatMap {
            [$0.cpuTemperature,
             showsLiquid ? $0.liquidTemperature : nil,
             showsGPU ? $0.gpuTemperature : nil].compactMap { $0 }
        }
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
                    context.stroke(grid, with: .color(Theme.border.opacity(0.7)), lineWidth: 0.5)
                }
                for item in series {
                    draw(item, context: &context, size: size)
                }
            }
            if samples.isEmpty {
                Text(L10n.text("noHistory"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack {
                Text("\(Int(limits.upperBound))°")
                Spacer()
                Text("\(Int(limits.lowerBound))°")
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(Theme.tertiaryInk)
            .padding(.leading, 2)
        }
        .accessibilityLabel(L10n.text("history"))
    }

    private func draw(_ item: Series, context: inout GraphicsContext, size: CGSize) {
        guard samples.count > 1 else { return }
        let start = samples.first!.timestamp.timeIntervalSinceReferenceDate
        let end = samples.last!.timestamp.timeIntervalSinceReferenceDate
        let duration = max(1, end - start)
        let span = limits.upperBound - limits.lowerBound

        var line = Path()
        var fill = Path()
        var hasPoint = false
        var segmentStart: CGPoint?

        func x(for sample: HistorySample) -> CGFloat {
            CGFloat(size.width * (sample.timestamp.timeIntervalSinceReferenceDate - start) / duration)
        }
        func y(for value: Double) -> CGFloat {
            let normalized = (value - limits.lowerBound) / span
            return size.height * (1 - min(1, max(0, normalized)))
        }

        for sample in samples {
            guard let value = sample[keyPath: item.keyPath] else {
                hasPoint = false
                if let start = segmentStart {
                    closeFill(&fill, from: start, to: line.currentPoint ?? start, size: size)
                    segmentStart = nil
                }
                continue
            }
            let point = CGPoint(x: x(for: sample), y: y(for: value))
            if hasPoint {
                line.addLine(to: point)
            } else {
                line.move(to: point)
                segmentStart = point
            }
            hasPoint = true
        }
        if let segmentStart {
            closeFill(&fill, from: segmentStart, to: line.currentPoint ?? segmentStart, size: size)
        }

        if !fill.isEmpty {
            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [item.color.opacity(0.20), item.color.opacity(0.015)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }
        context.stroke(line, with: .color(item.color), lineWidth: 1.6)
    }

    private func closeFill(_ fill: inout Path, from start: CGPoint, to end: CGPoint, size: CGSize) {
        fill.move(to: CGPoint(x: start.x, y: size.height))
        fill.addLine(to: start)
        fill.addLine(to: end)
        fill.addLine(to: CGPoint(x: end.x, y: size.height))
        fill.closeSubpath()
    }
}

struct ChartLegend: View {
    let showsLiquid: Bool
    let showsGPU: Bool

    var body: some View {
        HStack(spacing: 12) {
            legend("CPU", Theme.cpuLine)
            if showsLiquid { legend(L10n.text("liquid"), Theme.liquidLine) }
            if showsGPU { legend("GPU", Theme.gpuLine) }
        }
        .font(.system(size: 9, weight: .medium))
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 10, height: 2.5)
            Text(title).foregroundStyle(Theme.secondaryInk)
        }
    }
}

struct SteppedLever<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, options.count)
            let segment = geometry.size.width / CGFloat(count)
            let index = options.firstIndex { $0.value == selection } ?? 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.surfaceMuted)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.accentSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1)
                    )
                    .frame(width: max(0, segment - 4))
                    .offset(x: CGFloat(index) * segment + 2)
                    .animation(.easeOut(duration: 0.16), value: selection)
                HStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        Text(option.label)
                            .font(.system(size: 11, weight: selection == option.value ? .semibold : .regular))
                            .foregroundStyle(selection == option.value ? Theme.accent : Theme.secondaryInk)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let raw = Int(value.location.x / segment)
                        let index = min(count - 1, max(0, raw))
                        if options[index].value != selection {
                            selection = options[index].value
                        }
                    }
            )
        }
        .frame(height: 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("sampling"))
        .accessibilityValue(options.first { $0.value == selection }?.label ?? "")
        .accessibilityAdjustableAction { direction in
            let index = options.firstIndex { $0.value == selection } ?? 0
            switch direction {
            case .increment:
                if index + 1 < options.count { selection = options[index + 1].value }
            case .decrement:
                if index > 0 { selection = options[index - 1].value }
            @unknown default:
                break
            }
        }
    }
}

enum LightingPalette {
    static let colors: [Color] = [
        Color(red: 1, green: 1, blue: 1),
        Color(red: 1, green: 0.82, blue: 0.62),
        Color(red: 0.85, green: 0.38, blue: 0.27),
        Color(red: 1, green: 0.16, blue: 0.16),
        Color(red: 0.2, green: 0.85, blue: 0.45),
        Color(red: 0, green: 0.5, blue: 1),
        Color(red: 0.6, green: 0.3, blue: 1),
    ]

    static func rgb(_ color: Color) -> (Double, Double, Double)? {
        guard let value = NSColor(color).usingColorSpace(.deviceRGB) else { return nil }
        return (Double(value.redComponent), Double(value.greenComponent), Double(value.blueComponent))
    }

    static func apply(_ color: Color, to settings: inout LightingSettings) {
        guard let (red, green, blue) = rgb(color) else { return }
        settings.red = red
        settings.green = green
        settings.blue = blue
    }

    static func matches(_ settings: LightingSettings, _ color: Color) -> Bool {
        guard let (red, green, blue) = rgb(color) else { return false }
        return abs(settings.red - red) < 0.02
            && abs(settings.green - green) < 0.02
            && abs(settings.blue - blue) < 0.02
    }
}

struct ColorSwatch: View {
    let color: Color
    let selected: Bool
    var size: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .overlay(
                    Circle().strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.description)
    }
}

struct EffectChip: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 9, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Theme.accent : Theme.secondaryInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                selected ? Theme.accentSoft : Theme.surfaceMuted,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Theme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}



struct ModeSwitch: View {
    @Binding var isAutomatic: Bool
    var enabled = true
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(isAutomatic ? L10n.text("automatic") : L10n.text("manual"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isAutomatic ? Theme.cool : Theme.secondaryInk)
            Toggle("", isOn: Binding(
                get: { isAutomatic },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Theme.cool)
            .disabled(!enabled)
        }
    }
}

struct FanControlRow: View {
    let name: String
    let symbol: String
    @Binding var target: Double
    let minimum: Double
    let rpm: Int?
    var actualDuty: Int?
    var noTach = false
    var enabled = true
    var mode: String?
    var modeColor: Color = Theme.secondaryInk
    let onCommit: () -> Void

    private var rpmText: String {
        noTach ? L10n.text("noTach") : (rpm.map { "\($0) RPM" } ?? "-- RPM")
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(width: 14)
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if let mode {
                    Pill(text: mode, color: modeColor)
                }
                Spacer(minLength: 6)
                Text(rpmText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondaryInk)
                if let actualDuty {
                    Text("· \(L10n.text("readback")) \(actualDuty)%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryInk)
                }
                Text("\(Int(target.rounded()))%")
                    .font(Typography.numeral(12))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, alignment: .trailing)
            }
            Slider(value: roundedTarget, in: minimum...100, onEditingChanged: { editing in
                if !editing { onCommit() }
            })
            .tint(Theme.accent)
            .controlSize(.small)
            .disabled(!enabled)
        }
    }

    private var roundedTarget: Binding<Double> {
        Binding(
            get: { target },
            set: { target = min(100, max(minimum, $0.rounded())) }
        )
    }
}

struct PresetChip: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9, design: .monospaced))
                    .opacity(0.72)
            }
            .foregroundStyle(selected ? Theme.accent : Theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                selected ? Theme.accentSoft : Theme.surfaceMuted,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Theme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct FanServiceAlertBanner: View {
    let title: String
    let message: String
    let actionTitle: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 6)
                Button(actionTitle, action: action)
                    .buttonStyle(ClaudeSecondaryButtonStyle())
            }
            Text(message)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.30), lineWidth: 1)
        )
    }
}

struct NoticeBanner: View {
    let text: String
    var tint: Color = Theme.warm

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
