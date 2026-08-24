import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = PanelController()

        // Warm the event cache so the first ⌥Space shows events immediately
        // (only when access is already granted — never prompt at launch).
        if CalendarService.shared.hasFullAccess {
            Task { await CalendarService.shared.preload(around: Date()) }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "calendar.badge.plus",
            accessibilityDescription: "Calnip"
        )

        let menu = NSMenu()
        let newEvent = NSMenuItem(title: "New Event", action: #selector(togglePanel), keyEquivalent: " ")
        newEvent.keyEquivalentModifierMask = .option
        newEvent.target = self
        menu.addItem(newEvent)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Calnip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu

        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            DispatchQueue.main.async { self?.togglePanel() }
        }

        // Scriptable toggle (handy for testing):
        //   DistributedNotificationCenter post "com.avi.calnip.toggle"
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(togglePanel),
            name: Notification.Name("com.avi.calnip.toggle"),
            object: nil
        )
    }

    @objc private func togglePanel() {
        panelController.toggle()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }
}
