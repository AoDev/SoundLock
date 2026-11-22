import Cocoa
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var hostingController: NSHostingController<AnyView>?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var guardStateObserver: AnyCancellable?
    private var popoverClosedAt = Date.distantPast

    private let repository = PriorityListRepository()
    private let volume = AudioVolumeService()
    private let mute = AudioMuteService()
    let settings = AppSettings()
    lazy var monitor = AudioDeviceMonitor(volume: volume, mute: mute, repository: repository)
    private let newDevicePrompt = NewDevicePromptController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        setupStatusItem()
        observeGuardState()

        let contentView = AnyView(
            ContentView()
                .environmentObject(monitor)
                .environmentObject(volume)
                .environmentObject(mute)
                .environmentObject(settings)
        )
        let hc = NSHostingController(rootView: contentView)
        hostingController = hc
        popover = NSPopover()
        popover?.animates = false
        popover?.behavior = .transient
        popover?.contentViewController = hc
        popover?.delegate = self

        monitor.onNewOutputDevice = { [weak self] device in
            self?.promptToSwitch(to: device)
        }
        monitor.startMonitoring()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceCenter.addObserver(self, selector: #selector(handleSystemSleep(_:)), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceCenter.addObserver(self, selector: #selector(handleSystemWake(_:)), name: name, object: nil)
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShowPopoverRequest(_:)),
            name: Constants.showPopoverNotification,
            object: nil
        )
        if !launchedAsLoginItem() {
            showPopoverWhenStatusItemIsLaidOut()
        }
    }

    @objc private func handleSystemSleep(_ notification: Notification) {
        monitor.promptsSuppressedUntil = .distantFuture
        newDevicePrompt.dismiss()
    }

    @objc private func handleSystemWake(_ notification: Notification) {
        monitor.promptsSuppressedUntil = Date().addingTimeInterval(Constants.Timing.wakePromptSuppression)
    }

    private func promptToSwitch(to device: AudioDevice) {
        guard settings.promptOnNewOutputDevice else { return }
        newDevicePrompt.prompt(for: device, monitor: monitor, below: statusItem?.button?.window?.frame)
    }

    private func showPopoverWhenStatusItemIsLaidOut(attemptsLeft: Int = 30) {
        guard attemptsLeft > 0, statusItem?.button?.window?.frame.height == 0 else {
            showPopover()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.showPopoverWhenStatusItemIsLaidOut(attemptsLeft: attemptsLeft - 1)
        }
    }

    private func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    @objc private func handleShowPopoverRequest(_ notification: Notification) {
        showPopover()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        stopEventMonitors()
        closePopover(notification)
        monitor.stopMonitoring()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = statusBarImage(locked: monitor.guardEnabled)
            button.imageScaling = .scaleProportionallyUpOrDown
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: .leftMouseDown)
        }
    }

    private func observeGuardState() {
        guardStateObserver = monitor.$guardEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] locked in
                self?.statusItem?.button?.image = self?.statusBarImage(locked: locked)
            }
    }

    private func statusBarImage(locked: Bool) -> NSImage? {
        let resource = locked ? "StatusIcon" : "StatusIconUnlocked"
        let description = locked ? "SoundLock — locked" : "SoundLock — unlocked"

        if let path = Bundle.main.path(forResource: resource, ofType: "png"),
           let image = NSImage(contentsOfFile: path) {
            image.isTemplate = true
            image.size = NSSize(width: 24, height: 24)
            image.accessibilityDescription = description
            return image
        }

        return NSImage(systemSymbolName: locked ? "lock.fill" : "lock.open",
                       accessibilityDescription: description)
    }

    @objc private func handleApplicationDidResignActive(_ notification: Notification) {
        closePopover(notification)
    }

    @objc private func closePopover(_ sender: Any?) {
        guard let popover, popover.isShown else { return }
        stopEventMonitors()
        popover.performClose(sender)
    }

    private func startEventMonitors() {
        stopEventMonitors()

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.closePopover(nil)
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, let popover = self.popover, popover.isShown else { return event }
            guard let eventWindow = event.window else { return event }

            let popoverWindow = popover.contentViewController?.view.window
            let statusWindow = self.statusItem?.button?.window
            if eventWindow === popoverWindow || eventWindow === statusWindow || eventWindow === self.newDevicePrompt.panel {
                return event
            }

            self.closePopover(nil)
            return event
        }
    }

    private func stopEventMonitors() {
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = Date()
        stopEventMonitors()
    }

    @objc func togglePopover(_ sender: Any?) {
        if popover?.isShown == true {
            closePopover(sender)
        } else if Date().timeIntervalSince(popoverClosedAt) > Constants.Timing.popoverReopenGuard {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, let popover, !popover.isShown else { return }
        let screen = button.window?.screen ?? NSScreen.main
        let maxHeight = (screen?.visibleFrame.height ?? 800) - Constants.UI.popoverEdgeInset
        let ideal = hostingController?.sizeThatFits(
            in: NSSize(width: Constants.UI.popoverWidth, height: .greatestFiniteMagnitude)
        )
        let height = min(ideal?.height ?? Constants.UI.popoverDefaultHeight, maxHeight)
        popover.contentSize = NSSize(width: Constants.UI.popoverWidth, height: height)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startEventMonitors()
        NSApp.activate(ignoringOtherApps: true)
    }
}
