import AppKit
import InputMethodKit

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
  private var server: IMKServer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard
      let connection = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName")
        as? String,
      let identifier = Bundle.main.bundleIdentifier
    else {
      NSLog("Feather Input 缺少 InputMethodKit bundle 元数据")
      NSApplication.shared.terminate(nil)
      return
    }
    server = IMKServer(name: connection, bundleIdentifier: identifier)
    if server == nil {
      NSLog("Feather Input 无法创建 IMKServer")
      NSApplication.shared.terminate(nil)
    }
  }
}

@main
struct FeatherInputRustDevMain {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
  }
}
