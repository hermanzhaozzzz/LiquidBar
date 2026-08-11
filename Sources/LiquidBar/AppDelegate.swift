import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()
        observeModel()
        observeLifecycle()
        model.notifications.onNotificationActivated = { [weak self] in self?.showPopover() }
        model.start()
        if CommandLine.arguments.contains("--show-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showPopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
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
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                model: model,
                openSettings: { [weak self] in self?.showSettings() },
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
        NotificationCenter.default.addObserver(
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
            Task { @MainActor in self?.model.refreshNotificationAuthorization() }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let color: NSColor
        let prefix: String
        switch model.severity {
        case .normal:
            color = .labelColor
            prefix = ""
        case .warning:
            color = .systemOrange
            prefix = "⚠ "
        case .critical:
            color = .systemRed
            prefix = "⚠ "
        }
        button.attributedTitle = NSAttributedString(
            string: prefix + model.menuBarText,
            attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ]
        )
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        model.setPopoverOpen(true)
        model.refreshNow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let controller = NSHostingController(
                rootView: SettingsView(
                    model: model,
                    store: model.settingsStore,
                    notifications: model.notifications
                )
            )
            let window = NSWindow(contentViewController: controller)
            window.title = "LiquidBar"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
