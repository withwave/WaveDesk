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
    }

    // WaveDesk: right-click the Dock icon -> bring the window back onto the
    // monitor the cursor is on.
    override func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
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
        AppDelegate.dockChannel?.invokeMethod("showOnCurrentMonitor", arguments: nil)
    }
}
