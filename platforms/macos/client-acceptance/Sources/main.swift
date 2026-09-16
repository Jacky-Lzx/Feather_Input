import AppKit

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
  private var controller: AcceptanceWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = AcceptanceWindowController()
    self.controller = controller
    controller.showWindow(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

@main
private enum FeatherInputClientAcceptanceMain {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
  }
}
