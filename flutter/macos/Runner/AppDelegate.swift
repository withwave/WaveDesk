import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    var launched = false;

    // WaveDesk: wired up by MainFlutterWindow once the main engine exists, so
    // the Dock menu can reach Flutter. The Dock menu is the one place that
    // stays reachable when the window itself is parked off-screen.
    static var dockChannel: FlutterMethodChannel?
    static var showOnCurrentMonitorTitle = "Show on current monitor"
    // Shown as a disabled header so the running build's version is readable
    // without digging through Settings -> About.
    static var versionTitle = ""
    // Kept so the title can be updated once Flutter hands over the translation.
    static var windowMenuItem: NSMenuItem?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
      dummy_method_to_enforce_bundling()
    // https://github.com/leanflutter/window_manager/issues/214
    return false
  }
    
    override func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if (launched) {
            handle_applicationShouldOpenUntitledFile();
        }
        return true
    }
    
    override func applicationDidFinishLaunching(_ aNotification: Notification) {
        launched = true;
        NSApplication.shared.activate(ignoringOtherApps: true);
        installWindowMenuItem()
    }

    // WaveDesk: same action as the Dock menu, in the menu bar's Window menu.
    // Inserted at the top because AppKit appends the open-window list below.
    func installWindowMenuItem() {
        guard AppDelegate.windowMenuItem == nil, let menu = NSApp.windowsMenu else { return }
        let item = NSMenuItem(
            title: AppDelegate.showOnCurrentMonitorTitle,
            action: #selector(showOnCurrentMonitor(_:)),
            keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(NSMenuItem.separator(), at: 1)
        AppDelegate.windowMenuItem = item
    }

    // WaveDesk: right-click the Dock icon -> bring the window back onto the
    // monitor the cursor is on.
    override func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if !AppDelegate.versionTitle.isEmpty {
            let v = NSMenuItem(title: AppDelegate.versionTitle, action: nil, keyEquivalent: "")
            v.isEnabled = false
            menu.addItem(v)
            menu.addItem(NSMenuItem.separator())
        }
        let item = NSMenuItem(
            title: AppDelegate.showOnCurrentMonitorTitle,
            action: #selector(showOnCurrentMonitor(_:)),
            keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc func showOnCurrentMonitor(_ sender: Any?) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Done natively on purpose: picking the screen in Dart meant matching a
        // screen_retriever cursor point against window_size frames, and those
        // two disagree on the Y flip once a second monitor exists
        // (screen_retriever flips against the SMALLEST frame.maxY of all
        // screens, not the primary's height). Here everything is Cocoa
        // coordinates, so any monitor arrangement works.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let window = NSApp.windows.first(where: { $0 is MainFlutterWindow })
            ?? NSApp.mainWindow
            ?? NSApp.windows.first
        guard let target = screen, let win = window else {
            // No window yet (or no screens): let Flutter try.
            AppDelegate.dockChannel?.invokeMethod("showOnCurrentMonitor", arguments: nil)
            return
        }
        let vf = target.visibleFrame
        var f = win.frame
        f.size.width = min(f.width, vf.width)
        f.size.height = min(f.height, vf.height)
        f.origin.x = vf.midX - f.width / 2
        f.origin.y = vf.midY - f.height / 2
        if win.isMiniaturized { win.deminiaturize(nil) }
        win.setFrame(f, display: true)
        win.makeKeyAndOrderFront(nil)
    }
}
