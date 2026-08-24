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

        // Ask for calendar access up front, tied to launch — if the prompt
        // appeared only once the panel was open, typing into the panel could
        // answer (and deny) the focused permission dialog by accident.
        Task { @MainActor in
            let granted = await CalendarService.shared.requestAccess()
            if granted {
                await CalendarService.shared.preload(around: Date())
            }
            // First launch: open the panel so launching visibly does something.
            if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
                UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
                panelController.show()
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "calendar.badge.plus",
            accessibilityDescription: "Calnip"
        )
        statusItem.button?.toolTip = "Calnip"
        statusItem.isVisible = Settings.showMenuBarIcon
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification, object: nil)

        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let title = NSMenuItem(title: version.isEmpty ? "Calnip" : "Calnip \(version)",
                               action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
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

    /// Launching the app again (e.g. double-click in Finder) opens the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        panelController.show()
        return false
    }

    @objc private func togglePanel() {
        panelController.toggle()
    }

    @objc private func hotkeyChanged() {
        registerLaunchHotKey()
    }

    @objc private func defaultsChanged() {
        statusItem.isVisible = Settings.showMenuBarIcon
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
