import AppKit
import Darwin
import Foundation

private struct HarnessPaths {
  let sharedData: URL
  let userData: URL
  let schema: String

  static func application() throws -> Self {
    guard let resources = Bundle.main.resourceURL else {
      throw FeatherBridgeError.sessionCreationFailed
    }
    let sharedData = resources.appendingPathComponent("rime", isDirectory: true)
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let userData =
      applicationSupport
      .appendingPathComponent("FeatherInputRustDev", isDirectory: true)
      .appendingPathComponent("Rime", isDirectory: true)
    return Self(
      sharedData: sharedData,
      userData: userData,
      schema: ProcessInfo.processInfo.environment["FEATHER_RIME_SCHEMA"] ?? "luna_pinyin_simp"
    )
  }

  static func smokeTest() throws -> (Self, URL) {
    guard let resources = Bundle.main.resourceURL else {
      throw FeatherBridgeError.sessionCreationFailed
    }
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-dev-harness-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    return (
      Self(
        sharedData: resources.appendingPathComponent("rime", isDirectory: true),
        userData: temporaryRoot.appendingPathComponent("user", isDirectory: true),
        schema: "luna_pinyin_simp"
      ),
      temporaryRoot
    )
  }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
  private var controller: HarnessWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      let paths = try HarnessPaths.application()
      let session = try FeatherSession(
        sharedData: paths.sharedData,
        userData: paths.userData,
        schema: paths.schema
      )
      let controller = HarnessWindowController(
        session: session,
        sharedData: paths.sharedData,
        userData: paths.userData,
        schema: paths.schema
      )
      self.controller = controller
      try controller.start()
    } catch {
      let alert = NSAlert(error: error)
      alert.runModal()
      NSApplication.shared.terminate(nil)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

@main
struct FeatherDevHarnessMain {
  @MainActor
  static func main() {
    if CommandLine.arguments.contains("--smoke-test") {
      exit(runSmokeTest())
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    application.delegate = delegate
    application.activate(ignoringOtherApps: true)
    application.run()
  }

  @MainActor
  private static func runSmokeTest() -> Int32 {
    do {
      let (paths, temporaryRoot) = try HarnessPaths.smokeTest()
      defer { try? FileManager.default.removeItem(at: temporaryRoot) }
      let session = try FeatherSession(
        sharedData: paths.sharedData,
        userData: paths.userData,
        schema: paths.schema
      )
      _ = try session.activate()
      for character in "nihao" {
        _ = try session.send(text: String(character))
      }
      let response = try session.send(.space)
      guard response.commit == "你好" else {
        FileHandle.standardError.write(
          Data("Smoke test 失败：预期提交“你好”，实际为 \(response.commit ?? "nil")\n".utf8)
        )
        return 1
      }
      print("Smoke test 通过：Swift → C ABI → Rust → librime 提交“你好”")
      return 0
    } catch {
      FileHandle.standardError.write(Data("Smoke test 失败：\(error.localizedDescription)\n".utf8))
      return 1
    }
  }
}
