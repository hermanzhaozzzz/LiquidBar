import Foundation
import AppKit
import Testing
@testable import LiquidBar

@Test @MainActor
func menuBarSelectsCPUOrGPUWithoutChangingLiquidPreference() {
    #expect(AppModel.formatMenuBarText(cpuTemperature: 61.2, liquidTemperature: nil,
                                      showLiquidTemperature: false, gpuTemperature: 52.4,
                                      temperatureDisplay: .gpu) == "GPU 52°")
    #expect(AppModel.formatMenuBarText(cpuTemperature: 61.2, liquidTemperature: nil,
                                      showLiquidTemperature: false, gpuTemperature: 52.4,
                                      temperatureDisplay: .cpuAndGPU) == "CPU 61°  GPU 52°")
    #expect(AppModel.formatMenuBarText(cpuTemperature: 61.2, liquidTemperature: nil,
                                      showLiquidTemperature: false, gpuTemperature: 52.4,
                                      temperatureDisplay: .cpu) == "CPU 61°")
    let withLiquid = AppModel.formatMenuBarText(cpuTemperature: 61.2, liquidTemperature: 34,
                                               showLiquidTemperature: true, gpuTemperature: 52.4,
                                               temperatureDisplay: .gpu)
    #expect(withLiquid.hasPrefix("GPU 52°"))
    #expect(withLiquid.contains("34°"))
    #expect(!withLiquid.contains("CPU"))
}

@Test @MainActor
func menuBarNeverSubstitutesCPUForMissingOrStaleGPU() {
    let now = Date()
    let stale = GPUSnapshot(sampledAt: now.addingTimeInterval(-7),
                            devices: [GPUReading(id: 1, name: "Radeon", temperature: 52)])
    #expect(AppModel.formatMenuBarText(cpuTemperature: 61, liquidTemperature: nil,
                                      showLiquidTemperature: false,
                                      gpuTemperature: stale.primaryReading(now: now)?.temperature,
                                      temperatureDisplay: .gpu) == "GPU --°")
    #expect(AppModel.formatMenuBarText(cpuTemperature: 61, liquidTemperature: nil,
                                      showLiquidTemperature: false,
                                      temperatureDisplay: .cpuAndGPU) == "CPU 61°  GPU --°")
    #expect(AppModel.formatMenuBarText(cpuTemperature: 61, liquidTemperature: nil,
                                      showLiquidTemperature: false, gpuTemperature: .nan,
                                      temperatureDisplay: .gpu) == "GPU --°")
}

@Test @MainActor
func menuBarTemperaturePreferencePersistsWithoutChangingCoolingSettings() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SettingsStore(baseDirectory: directory)
    store.value.manualFanDuty = [42, 53, 61]
    store.value.showLiquidTemperatureInMenuBar = true
    for mode in MenuBarTemperatureDisplay.allCases {
        store.value.menuBarTemperatureDisplay = mode
        let restored = SettingsStore(baseDirectory: directory)
        #expect(restored.value.menuBarTemperatureDisplay == mode)
        #expect(restored.value.manualFanDuty == [42, 53, 61])
        #expect(restored.value.showLiquidTemperatureInMenuBar == true)
    }
}

@Test
func menuBarColorsUseEachSensorAndKeepGPUThresholdsVisualOnly() {
    var thresholds = AlertThresholds()
    thresholds.cpuWarning = 65
    thresholds.cpuCritical = 80
    let cpu = MenuBarTemperatureItem(sensor: .cpu, temperature: 70, thresholds: thresholds)
    let gpu = MenuBarTemperatureItem(sensor: .gpu, temperature: 69.9, thresholds: thresholds)
    let liquid = MenuBarTemperatureItem(sensor: .liquid, temperature: 46, thresholds: thresholds)
    #expect(cpu.level == .warning)
    #expect(gpu.level == .normal)
    #expect(liquid.level == .warning)
    #expect(MenuBarTemperatureItem(sensor: .gpu, temperature: 70, thresholds: thresholds).level == .warning)
    #expect(MenuBarTemperatureItem(sensor: .gpu, temperature: 85, thresholds: thresholds).level == .critical)
    #expect(MenuBarTemperatureItem(sensor: .gpu, temperature: nil, thresholds: thresholds).level == nil)
    #expect(MenuBarTemperatureItem(sensor: .gpu, temperature: .nan, thresholds: thresholds).formattedTemperature == "--°")
    #expect(ThermalPolicy.instantaneousSeverity(cpu: 60, liquid: nil, thresholds: thresholds) == .normal)
}

@Test @MainActor
func menuBarNativeSymbolsKeepIndependentColorsDuringCPUAlarm() throws {
    let items = AppModel.menuBarItems(cpuTemperature: 95, liquidTemperature: nil,
                                      showLiquidTemperature: false, gpuTemperature: 52,
                                      temperatureDisplay: .cpuAndGPU)
    let title = MenuBarTemperatureRenderer.title(items: items, alert: .critical)
    let string = title.string as NSString
    #expect(!title.string.contains("CPU"))
    #expect(!title.string.contains("GPU"))
    let cpuColor = title.attribute(.foregroundColor, at: string.range(of: "95°").location,
                                  effectiveRange: nil) as? NSColor
    let gpuColor = title.attribute(.foregroundColor, at: string.range(of: "52°").location,
                                  effectiveRange: nil) as? NSColor
    #expect(cpuColor?.usingColorSpace(.deviceRGB) == MenuBarTemperatureRenderer.color(for: .critical).usingColorSpace(.deviceRGB))
    #expect(gpuColor?.usingColorSpace(.deviceRGB) == MenuBarTemperatureRenderer.color(for: .normal).usingColorSpace(.deviceRGB))
    var images: [NSImage] = []
    title.enumerateAttribute(.attachment, in: NSRange(location: 0, length: title.length)) { value, _, _ in
        if let attachment = value as? NSTextAttachment,
           let image = (attachment.attachmentCell as? NSTextAttachmentCell)?.image { images.append(image) }
    }
    #expect(images.count == 2)
    #expect(images.allSatisfy { !$0.isTemplate })

    // Optional synthetic strips for visual review, never a live status-bar screenshot.
    guard let directory = ProcessInfo.processInfo.environment["LIQUIDBAR_STATUS_PREVIEW_DIR"] else { return }
    let cases: [(String, Double?, Double?, AlertSeverity)] = [
        ("Normal", 61, 52, .normal), ("CPU hot / GPU normal", 95, 52, .critical),
        ("GPU hot / CPU normal", 61, 86, .normal), ("GPU unavailable", 61, nil, .normal),
    ]
    for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        let appearance = try #require(NSAppearance(named: appearanceName))
        var png: Data?
        appearance.performAsCurrentDrawingAppearance {
            let image = NSImage(size: NSSize(width: 450, height: 155))
            image.lockFocus()
            NSColor.windowBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: 450, height: 155).fill()
            NSAttributedString(string: "SYNTHETIC STATUS ITEMS · " + name, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
            ]).draw(at: NSPoint(x: 16, y: 130))
            for (index, fixture) in cases.enumerated() {
                let y = CGFloat(103 - index * 28)
                NSAttributedString(string: fixture.0, attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
                ]).draw(at: NSPoint(x: 16, y: y))
                let fixtureItems = AppModel.menuBarItems(cpuTemperature: fixture.1, liquidTemperature: nil,
                                                        showLiquidTemperature: false, gpuTemperature: fixture.2,
                                                        temperatureDisplay: .cpuAndGPU)
                MenuBarTemperatureRenderer.title(items: fixtureItems, alert: fixture.3)
                    .draw(at: NSPoint(x: 230, y: y))
            }
            image.unlockFocus()
            if let tiff = image.tiffRepresentation {
                png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            }
        }
        let data = try #require(png)
        let destination = URL(fileURLWithPath: directory).appendingPathComponent("synthetic-status-\(name).png")
        try data.write(to: destination)
    }
}
