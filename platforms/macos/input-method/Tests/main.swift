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
    let presenter = SmokeCandidatePresenter()
    controller.candidatePresenter = presenter
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
    guard presenter.candidates.contains(where: { $0.text == "你好" }) else {
      throw SmokeFailure.expectation("候选窗口没有收到“你好”")
    }
    guard presenter.anchor == NSRect(x: 100, y: 100, width: 1, height: 20) else {
      throw SmokeFailure.expectation("候选窗口锚点错误")
    }
    let initialHighlight = presenter.highlighted
    let updateCountBeforeNavigation = presenter.updateCount
    guard controller.handle(key("", code: 125), client: client) else {
      throw SmokeFailure.expectation("向下键没有移动候选高亮")
    }
    guard presenter.highlighted != initialHighlight else {
      throw SmokeFailure.expectation("向下键被处理，但候选高亮没有变化")
    }
    guard controller.handle(key("", code: 126), client: client) else {
      throw SmokeFailure.expectation("向上键没有移动候选高亮")
    }
    guard presenter.highlighted == initialHighlight else {
      throw SmokeFailure.expectation("向上键没有恢复原候选高亮")
    }
    guard presenter.updateCount >= updateCountBeforeNavigation + 2 else {
      throw SmokeFailure.expectation("候选高亮变化没有刷新窗口")
    }

    presenter.select(text: "你好")
    guard client.committed == "你好" else {
      throw SmokeFailure.expectation("点击候选没有提交“你好”")
    }
    guard client.marked.isEmpty else {
      throw SmokeFailure.expectation("提交后 marked text 没有清空")
    }
    guard presenter.candidates.isEmpty else {
      throw SmokeFailure.expectation("提交后候选窗口没有隐藏")
    }

    for (character, keyCode) in zip("shijie", [1, 4, 34, 38, 34, 14]) {
      guard controller.handle(key(String(character), code: UInt16(keyCode)), client: client) else {
        throw SmokeFailure.expectation("拼音按键没有被处理：\(character)")
      }
    }
    let updateCountBeforePaging = presenter.updateCount
    presenter.pageDown()
    guard presenter.updateCount > updateCountBeforePaging else {
      throw SmokeFailure.expectation("候选翻页动作没有刷新窗口")
    }
    guard controller.handle(key("", code: 53), client: client) else {
      throw SmokeFailure.expectation("Escape 没有取消翻页后的组合")
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
