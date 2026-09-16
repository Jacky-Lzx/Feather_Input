import AppKit
import Darwin
import InputMethodKit

enum SmokeFailure: LocalizedError {
  case invalidArguments
  case controllerCreation
  case expectation(String)

  var errorDescription: String? {
    switch self {
    case .invalidArguments: return "需要共享数据目录和临时用户目录"
    case .controllerCreation: return "无法创建测试输入控制器"
    case .expectation(let message): return message
    }
  }
}

@main
struct InputMethodSmokeMain {
  @MainActor
  static func main() {
    do {
      try run()
      print("InputMethodKit Smoke Test 通过：预编辑、候选、上屏和事件放行")
    } catch {
      FileHandle.standardError.write(
        Data("InputMethodKit Smoke Test 失败：\(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  @MainActor
  private static func run() throws {
    guard CommandLine.arguments.count == 3 else { throw SmokeFailure.invalidArguments }
    FeatherInputEnvironment.sharedDataOverride = URL(fileURLWithPath: CommandLine.arguments[1])
    FeatherInputEnvironment.userDataOverride = URL(fileURLWithPath: CommandLine.arguments[2])
    guard
      TextCoordinates.utf16Offset(in: "你a", utf8Offset: 0) == 0,
      TextCoordinates.utf16Offset(in: "你a", utf8Offset: 3) == 1,
      TextCoordinates.utf16Offset(in: "你a", utf8Offset: 4) == 2
    else {
      throw SmokeFailure.expectation("UTF-8 到 UTF-16 光标转换错误")
    }
    guard let controller = InputController(server: nil, delegate: nil, client: nil) else {
      throw SmokeFailure.controllerCreation
    }
    controller.secureInputEnabled = { false }
    let client = SmokeTextClient()
    controller.activateServer(client)

    for (character, keyCode) in zip("nihao", [45, 34, 4, 0, 31]) {
      guard controller.handle(key(String(character), code: UInt16(keyCode)), client: client) else {
        throw SmokeFailure.expectation("拼音按键没有被处理：\(character)")
      }
    }
    guard !client.marked.isEmpty else {
      throw SmokeFailure.expectation("输入拼音后没有产生 marked text")
    }
    guard client.markedSelection.location <= client.marked.utf16.count else {
      throw SmokeFailure.expectation("marked text 的 UTF-16 光标越界")
    }
    let candidates = controller.candidates(client) as? [String] ?? []
    guard candidates.contains("你好") else {
      throw SmokeFailure.expectation("候选中缺少“你好”")
    }

    guard controller.handle(key(" ", code: 49), client: client), client.committed == "你好" else {
      throw SmokeFailure.expectation("空格没有提交“你好”")
    }
    guard client.marked.isEmpty else {
      throw SmokeFailure.expectation("提交后 marked text 没有清空")
    }

    guard controller.handle(key("A", code: 0, modifiers: .shift), client: client),
      client.committed == "你好", client.marked == "A"
    else {
      throw SmokeFailure.expectation(
        "中文模式没有保留 Shift 输入的大写字母：committed=\(client.committed)，marked=\(client.marked)"
      )
    }
    guard controller.handle(key("\u{1b}", code: 53), client: client), client.marked.isEmpty else {
      throw SmokeFailure.expectation("清除大写英文预编辑失败")
    }

    guard !controller.handle(key("c", code: 8, modifiers: .command), client: client) else {
      throw SmokeFailure.expectation("Command 快捷键不应被输入法消费")
    }
    controller.secureInputEnabled = { true }
    guard !controller.handle(key("n", code: 45), client: client) else {
      throw SmokeFailure.expectation("安全输入事件不应被输入法消费")
    }
    controller.secureInputEnabled = { false }
    client.selectionAvailable = false
    guard !controller.handle(key("n", code: 45), client: client) else {
      throw SmokeFailure.expectation("非文本客户端事件不应被输入法消费")
    }
    controller.deactivateServer(client)
  }

  private static func key(
    _ characters: String,
    code: UInt16,
    modifiers: NSEvent.ModifierFlags = []
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: code
    )!
  }
}
