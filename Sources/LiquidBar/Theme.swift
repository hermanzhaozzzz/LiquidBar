import AppKit
import SwiftUI

enum Theme {
    // Claude-inspired warm palette: ivory canvas, charcoal ink, terracotta accent.
    static let canvas = dynamic(light: 0xF7F5EF, dark: 0x1A1917)
    static let surface = dynamic(light: 0xFDFCF8, dark: 0x24221F)
    static let surfaceMuted = dynamic(light: 0xF0EDE3, dark: 0x2C2A26)
    static let surfaceStrong = dynamic(light: 0xE9E5D9, dark: 0x35322D)
    static let border = dynamic(light: 0xE3DFD2, dark: 0x3A3731)
    static let ink = dynamic(light: 0x23211D, dark: 0xF1EEE5)
    static let secondaryInk = dynamic(light: 0x6F6A60, dark: 0xACA79C)
    static let tertiaryInk = dynamic(light: 0x99948A, dark: 0x807B71)

    static let accent = dynamic(light: 0xC2603F, dark: 0xE08A6B)
    static let accentFill = dynamic(light: 0xD97757, dark: 0xD97757)
    static let accentSoft = dynamic(light: 0xF6E4DB, dark: 0x3B2C26)
    static let onAccent = Color(hex: 0xFFF9F5)

    static let cool = dynamic(light: 0x2F6F5E, dark: 0x7CC3A7)
    static let warm = dynamic(light: 0xA9611F, dark: 0xE5AE6B)
    static let hot = dynamic(light: 0xA83224, dark: 0xF0806A)

    static let cpuLine = dynamic(light: 0xC2603F, dark: 0xE08A6B)
    static let liquidLine = dynamic(light: 0x5F87A0, dark: 0x8FB6CC)
    static let gpuLine = dynamic(light: 0x8C7A3F, dark: 0xC9B775)

    static let shadow = Color.black.opacity(0.05)

    enum Radius {
        static let card: CGFloat = 12
        static let control: CGFloat = 8
        static let pill: CGFloat = 999
    }

    enum Spacing {
        static let page: CGFloat = 18
        static let card: CGFloat = 14
        static let row: CGFloat = 10
    }

    static func sensorColor(for severity: AlertSeverity) -> Color {
        switch severity {
        case .normal: return cool
        case .warning: return warm
        case .critical: return hot
        }
    }

    static func sensorNSColor(_ severity: AlertSeverity, dark: Bool) -> NSColor {
        switch severity {
        case .normal: return NSColor(hex: dark ? 0x7CC3A7 : 0x2F6F5E)
        case .warning: return NSColor(hex: dark ? 0xE5AE6B : 0xA9611F)
        case .critical: return NSColor(hex: dark ? 0xF0806A : 0xA83224)
        }
    }

    static func lineColor(for sensor: MenuBarSensor) -> Color {
        switch sensor {
        case .cpu: return cpuLine
        case .liquid: return liquidLine
        case .gpu: return gpuLine
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

enum Typography {
    static func wordmark(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }

    static func display(_ size: CGFloat = 26) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }

    static func sectionTitle() -> Font {
        .system(size: 13, weight: .semibold)
    }

    static func numeral(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

struct CardSurface: ViewModifier {
    var padding: CGFloat = Theme.Spacing.card

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}

extension View {
    func cardSurface(padding: CGFloat = Theme.Spacing.card) -> some View {
        modifier(CardSurface(padding: padding))
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(color.opacity(0.28), lineWidth: 3).scaleEffect(1.6))
    }
}

struct Pill: View {
    let text: String
    var color: Color = Theme.secondaryInk
    var icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct ClaudePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Theme.accentFill.opacity(configuration.isPressed ? 0.8 : 1),
                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            )
    }
}

struct ClaudeSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Theme.surfaceMuted.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}

struct ClaudeQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.secondaryInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                configuration.isPressed ? Theme.surfaceMuted : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.sectionTitle())
                    .foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .cardSurface(padding: 16)
    }
}

struct SettingRow<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            content
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: 1)
    }
}

struct EmptyHint: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondaryInk)
    }
}
