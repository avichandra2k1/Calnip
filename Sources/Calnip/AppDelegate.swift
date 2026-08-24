import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var hotKey: HotKey?
    private var newEventItem: NSMenuItem?

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
        newEventItem = newEvent
        menu.addItem(newEvent)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Calnip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu

        registerLaunchHotKey()
        NotificationCenter.default.addObserver(
            self, selector: #selector(hotkeyChanged),
            name: .calnipHotkeyChanged, object: nil)

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

    @objc private func hotkeyChanged() {
        registerLaunchHotKey()
    }

    private func registerLaunchHotKey() {
        // Replacing the HotKey unregisters the old one in its deinit.
        hotKey = HotKey(keyCode: UInt32(Settings.launchKeyCode),
                        modifiers: UInt32(Settings.launchModifiers)) { [weak self] in
            DispatchQueue.main.async { self?.togglePanel() }
        }
        updateMenuShortcut()
    }

    /// Best-effort mirror of the hotkey in the status menu.
    private func updateMenuShortcut() {
        guard let item = newEventItem else { return }
        let keyName = Settings.launchDisplay.components(separatedBy: " ").last ?? ""
        if Settings.launchKeyCode == 49 {
            item.keyEquivalent = " "
        } else if keyName.count == 1 {
            item.keyEquivalent = keyName.lowercased()
        } else {
            item.keyEquivalent = ""
        }
        var mask: NSEvent.ModifierFlags = []
        let mods = Settings.launchModifiers
        if mods & 0x0100 != 0 { mask.insert(.command) }
        if mods & 0x0200 != 0 { mask.insert(.shift) }
        if mods & 0x0800 != 0 { mask.insert(.option) }
        if mods & 0x1000 != 0 { mask.insert(.control) }
        item.keyEquivalentModifierMask = mask
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }
}
