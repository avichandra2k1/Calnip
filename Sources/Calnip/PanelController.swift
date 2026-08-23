import AppKit
import SwiftUI

/// Borderless panel that can take keyboard focus without activating the app.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// ⌘1–9 quick calendar pick; returns true if handled.
    var onCommandDigit: ((Int) -> Bool)?
    /// ⌘, opens settings.
    var onCommandComma: (() -> Void)?
    /// ⌘E edits the selected event.
    var onCommandE: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let char = event.charactersIgnoringModifiers?.first else {
            return super.performKeyEquivalent(with: event)
        }
        if let digit = char.wholeNumberValue, (1...9).contains(digit),
           onCommandDigit?(digit) == true {
            return true
        }
        if char == "," {
            onCommandComma?()
            return true
        }
        if char == "e" {
            onCommandE?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: FloatingPanel
    private let model = InputModel()
    private var desiredTopLeft: NSPoint = .zero

    override init() {
        panel = FloatingPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The glass material draws its own soft shadow; the window shadow would
        // outline the full (rectangular) Metal surface as a hairline box.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let hosting = NSHostingController(rootView: PanelView(model: model))
        hosting.sizingOptions = .preferredContentSize
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentViewController = hosting

        model.onDismiss = { [weak self] in self?.hide() }
        panel.onCommandDigit = { [weak self] digit in
            self?.model.pickCalendar(digit) ?? false
        }
        panel.onCommandComma = { [weak self] in
            self?.hide()
            SettingsWindowController.shared.show()
        }
        panel.onCommandE = { [weak self] in
            self?.model.beginEdit()
        }

        // Keep the top edge pinned as the panel grows/shrinks with content.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            self.panel.setFrameTopLeftPoint(self.desiredTopLeft)
            self.panel.invalidateShadow()
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        model.reset()
        model.prepare()

        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            panel.layoutIfNeeded()
            let size = panel.frame.size
            desiredTopLeft = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - frame.height * 0.25
            )
            panel.setFrameTopLeftPoint(desiredTopLeft)
        }

        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        NotificationCenter.default.post(name: .calnipPanelDidShow, object: nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
