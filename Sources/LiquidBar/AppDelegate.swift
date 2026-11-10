import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let settingsNavigation = SettingsNavigation()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private var isPreview: Bool { CommandLine.arguments.contains("--ui-preview") }

    private var previewAppearance: NSAppearance? {
        guard isPreview, CommandLine.arguments.contains("--dark") else { return nil }
        return NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--dark") {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        configureStatusItem()
        configurePopover()
        observeModel()
        observeLifecycle()
        model.notifications.onNotificationActivated = { [weak self] in self?.showPopover() }
        if isPreview {
            model.loadPreviewState()
        } else {
            model.start()
        }
        model.refreshNotificationAuthorization()

        if CommandLine.arguments.contains("--show-onboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showOnboarding()
            }
        } else if CommandLine.arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showSettings()
            }
        } else if CommandLine.arguments.contains("--show-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showPopover()
            }
        } else if !isPreview {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let audit = await self.model.auditPermissions()
                self.handlePermissionAudit(audit)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isPreview {
            return .terminateNow
        }
        Task {
            let completed = await model.stop()
            sender.reply(toApplicationShouldTerminate: completed)
            if !completed { showPopover() }
        }
        return .terminateLater
    }

    func popoverDidClose(_ notification: Notification) {
        model.setPopoverOpen(false)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
        button.toolTip = "LiquidBar"
        updateStatusItem()
    }

    private func configurePopover() {
        popover.behavior = isPreview ? .applicationDefined : .transient
        popover.animates = !isPreview
        popover.appearance = previewAppearance
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                model: model,
                store: model.settingsStore,
                openSettings: { [weak self] in self?.showSettings() },
                openFanService: { [weak self] in self?.showSettings(pane: .motherboard) },
                quit: { NSApplication.shared.terminate(nil) }
            )
        )
    }

    private func observeModel() {
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)

        model.settingsStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)
    }

    private func observeLifecycle() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.model.handleSleep() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model.handleWake() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.refreshNotificationAuthorization()
                self?.model.refreshLoginItemStatus()
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let items = model.menuBarItems
        var help = ["LiquidBar", model.menuBarText]
        if items.contains(where: { $0.sensor == .gpu }) { help.append(L10n.text("menuBarGPUColorHelp")) }
        if model.severity != .normal { help.append(L10n.text("menuBarAlertHelp")) }
        button.toolTip = help.joined(separator: "\n")
        button.setAccessibilityLabel("LiquidBar, " + model.menuBarText)
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            button.attributedTitle = MenuBarTemperatureRenderer.title(items: items, alert: model.severity)
        }
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        model.setPopoverOpen(true)
        if !isPreview { model.refreshNow() }
        if isPreview { NSApplication.shared.activate(ignoringOtherApps: true) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showSettings(pane: SettingsPane? = nil) {
        popover.performClose(nil)
        if let pane { settingsNavigation.pane = pane }
        if settingsWindow == nil {
            let controller = NSHostingController(
                rootView: SettingsView(
                    model: model,
                    store: model.settingsStore,
                    notifications: model.notifications,
                    navigation: settingsNavigation,
                    showOnboarding: { [weak self] in
                        self?.settingsWindow?.close()
                        self?.showOnboarding()
                    }
                )
            )
            let window = NSWindow(contentViewController: controller)
            window.title = "LiquidBar"
            window.appearance = previewAppearance
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func handlePermissionAudit(_ audit: PermissionAudit) {
        let store = model.settingsStore
        guard audit.needsAttention else {
            // Forget the previous shortfall so a later permission loss prompts again.
            if store.value.lastPermissionPromptFingerprint != nil {
                store.value.lastPermissionPromptFingerprint = nil
            }
            if store.value.setupCompleted != true {
                store.value.setupCompleted = true
            }
            return
        }
        guard store.value.lastPermissionPromptFingerprint != audit.fingerprint else { return }
        store.value.lastPermissionPromptFingerprint = audit.fingerprint
        showOnboarding(step: audit.onboardingStep)
    }

    private func showOnboarding(step: Int? = nil) {
        popover.performClose(nil)
        if onboardingWindow == nil {
            let controller = NSHostingController(
                rootView: OnboardingView(
                    model: model,
                    notifications: model.notifications,
                    startAt: step
                ) { [weak self] in
                    self?.onboardingWindow?.close()
                    self?.onboardingWindow = nil
                }
            )
            let window = NSWindow(contentViewController: controller)
            window.title = L10n.text("setupAssistant")
            window.appearance = previewAppearance
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
enum MenuBarTemperatureRenderer {
    static func color(for level: AlertSeverity?) -> NSColor {
        guard let level else { return .secondaryLabelColor }
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return Theme.sensorNSColor(level, dark: dark)
        }
    }

    static func title(items: [MenuBarTemperatureItem], alert: AlertSeverity) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let result = NSMutableAttributedString()
        if alert != .normal {
            result.append(NSAttributedString(string: "⚠\u{2009}", attributes: [
                .font: font, .foregroundColor: color(for: alert),
            ]))
        }
        for (index, item) in items.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            let tint = color(for: item.level)
            if let image = image(for: item) {
                let attachment = NSTextAttachment()
                attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
                let icon = NSMutableAttributedString(attachment: attachment)
                icon.addAttribute(.baselineOffset, value: -1.5, range: NSRange(location: 0, length: icon.length))
                result.append(icon)
            } else {
                result.append(NSAttributedString(string: item.sensor.label, attributes: [.font: font, .foregroundColor: tint]))
            }
            result.append(NSAttributedString(string: "\u{2009}" + item.formattedTemperature,
                                              attributes: [.font: font, .foregroundColor: tint]))
        }
        return result
    }

    static func image(for item: MenuBarTemperatureItem) -> NSImage? {
        let tint = color(for: item.level)
        if item.sensor == .gpu { return graphicsCardImage(tint: tint) }
        guard let name = item.sensor.symbol else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: item.sensor.label)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }

    // Native vector artwork stays sharp on 1x and Retina displays; a PCIe-card
    // SF Symbol is not available on all supported macOS releases.
    static func graphicsCardImage(tint: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { _ in
            tint.setStroke()
            let body = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 3.5, width: 14, height: 9), xRadius: 1.2, yRadius: 1.2)
            body.lineWidth = 1.1
            body.stroke()
            let bracket = NSBezierPath()
            bracket.lineWidth = 1.1
            bracket.move(to: NSPoint(x: 1, y: 2))
            bracket.line(to: NSPoint(x: 1, y: 12.5))
            bracket.line(to: NSPoint(x: 3, y: 12.5))
            for x in [6.0, 8.0, 10.0, 12.0] {
                bracket.move(to: NSPoint(x: x, y: 3.5))
                bracket.line(to: NSPoint(x: x, y: 1.8))
            }
            bracket.stroke()
            for x in [6.5, 12.5] {
                let fan = NSBezierPath(ovalIn: NSRect(x: x - 2.1, y: 5.9, width: 4.2, height: 4.2))
                fan.lineWidth = 0.9
                for angle in [0.0, 2.094, 4.189] {
                    fan.move(to: NSPoint(x: x, y: 8))
                    fan.line(to: NSPoint(x: x + cos(angle) * 1.5, y: 8 + sin(angle) * 1.5))
                }
                fan.stroke()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "GPU"
        return image
    }
}
