import AppKit
import Combine
import SwiftUI

final class NewDevicePromptController {
    private(set) var panel: NSPanel?
    private var dismissItem: DispatchWorkItem?
    private var deviceWatch: AnyCancellable?

    func prompt(for device: AudioDevice, monitor: AudioDeviceMonitor, below anchor: NSRect?) {
        let hasInput = monitor.pairedInput(for: device) != nil
        show(deviceName: device.name, hasInput: hasInput, below: anchor) { [weak monitor] includeInput in
            monitor?.switchTo(device, input: false)
            if includeInput, let input = monitor?.pairedInput(for: device) {
                monitor?.switchTo(input, input: true)
            }
        }
        deviceWatch = monitor.$outputDevices.combineLatest(monitor.$inputDevices, monitor.$defaultOutputID)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak monitor] outputs, _, defaultOutputID in
                guard let self, let monitor else { return }
                guard let live = outputs.first(where: { $0.uid == device.uid }), live.id != defaultOutputID else {
                    self.dismiss()
                    return
                }
                if !hasInput, monitor.pairedInput(for: device) != nil {
                    self.prompt(for: device, monitor: monitor, below: anchor)
                }
            }
    }

    func show(deviceName: String, hasInput: Bool, below anchor: NSRect?, onSwitch: @escaping (_ includeInput: Bool) -> Void) {
        dismiss()

        let view = NewDevicePromptView(
            deviceName: deviceName,
            hasInput: hasInput,
            onSwitch: { [weak self] includeInput in
                onSwitch(includeInput)
                self?.dismiss()
            },
            onClose: { [weak self] in self?.dismiss() }
        )
        let hosting = FirstMouseHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.masksToBounds = true
        let size = hosting.fittingSize

        let panel = PromptPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let screen = NSScreen.screens.first { anchor.map($0.frame.intersects) ?? false } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let preferredX = anchor.map { $0.midX - size.width / 2 } ?? frame.maxX - size.width
            let x = min(max(preferredX, frame.minX + 8), frame.maxX - size.width - 8)
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: frame.maxY - 6))
        }
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        self.panel = panel

        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.newDevicePromptDuration, execute: item)
    }

    func dismiss() {
        deviceWatch = nil
        dismissItem?.cancel()
        dismissItem = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct NewDevicePromptView: View {
    let deviceName: String
    let hasInput: Bool
    let onSwitch: (Bool) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hifispeaker.and.homepod")
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor)
                    .frame(width: Theme.rowIconFrame)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New device connected")
                        .font(Theme.sectionTitleFont)
                        .foregroundColor(.secondary)
                    Text(deviceName)
                        .font(Theme.headerTitleFont)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Keep current devices")
                .cursor(.pointingHand)
            }
            HStack(spacing: 8) {
                Button("Switch Output") { onSwitch(false) }
                if hasInput {
                    Button("Output & Input") { onSwitch(true) }
                }
            }
            .controlSize(.small)
            .padding(.leading, Theme.rowIconFrame + 10)
        }
        .padding(14)
        .frame(width: Constants.UI.popoverWidth)
        .background(VisualEffectBackground(material: .hudWindow))
    }
}
