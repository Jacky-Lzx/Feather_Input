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
    try verifyInputModeMemory()
    try verifyInputSchemeMemory()
    try verifyCandidateOverlayOwnership()
    try verifyModeIndicatorOwnership()
    guard let controller = InputController(server: nil, delegate: nil, client: nil) else {
      throw SmokeFailure.controllerCreation
    }
    controller.secureInputEnabled = { false }
    let presenter = SmokeCandidatePresenter()
    let modePresenter = SmokeModePresenter()
    let modeDefaultsName = "FeatherInputMethodSmoke-\(UUID().uuidString)"
    guard let modeDefaults = UserDefaults(suiteName: modeDefaultsName) else {
      throw SmokeFailure.expectation("无法创建隔离的输入模式设置")
    }
    defer { modeDefaults.removePersistentDomain(forName: modeDefaultsName) }
    controller.candidatePresenter = presenter
    controller.modePresenter = modePresenter
    controller.modeMemory = InputModeMemory(defaults: modeDefaults)
    controller.schemeMemory = InputSchemeMemory(defaults: modeDefaults)
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
    guard client.lastAttributesCharacterIndex == 0,
      presenter.anchor == client.caretRectangle
    else {
      throw SmokeFailure.expectation("候选窗口没有使用 InputMethodKit 光标矩形")
    }
    let markedBeforeBoundaryPaging = client.marked
    guard controller.handle(key("", code: 123, modifiers: .function), client: client) else {
      throw SmokeFailure.expectation("第一页的向左翻页键没有被输入法消费")
    }
    guard client.marked == markedBeforeBoundaryPaging, !presenter.candidates.isEmpty else {
      throw SmokeFailure.expectation("第一页按左键不应取消组合或隐藏候选窗口")
    }
    let initialHighlight = presenter.highlighted
    let updateCountBeforeNavigation = presenter.updateCount
    client.caretRectangle = .zero
    guard controller.handle(key("", code: 125, modifiers: .function), client: client) else {
      throw SmokeFailure.expectation("向下键没有移动候选高亮")
    }
    guard presenter.anchor == NSRect(x: 100, y: 100, width: 1, height: 20) else {
      throw SmokeFailure.expectation("临时取不到光标矩形时没有保留最近有效位置")
    }
    client.caretRectangle = NSRect(x: 100, y: 100, width: 1, height: 20)
    guard presenter.highlighted != initialHighlight else {
      throw SmokeFailure.expectation("向下键被处理，但候选高亮没有变化")
    }
    guard controller.handle(key("", code: 126, modifiers: .function), client: client) else {
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

    guard
      !controller.handle(
        flags(code: 62, modifiers: [.control], timestamp: 1), client: client)
    else {
      throw SmokeFailure.expectation("按下右 Control 时不应立即切换输入模式")
    }
    guard controller.handle(flags(code: 62, modifiers: [], timestamp: 1.1), client: client),
      modePresenter.directMode == true,
      modePresenter.anchor == client.caretRectangle,
      modePresenter.isVisible,
      modePresenter.showCount == 1
    else {
      throw SmokeFailure.expectation("单击右 Control 没有切换到英文模式")
    }
    guard !controller.handle(key("n", code: 45), client: client), client.marked.isEmpty else {
      throw SmokeFailure.expectation("英文模式没有把文字按键交还客户端")
    }
    guard
      controller.handle(
        key(" ", code: 49, modifiers: [.control, .shift]), client: client),
      modePresenter.directMode == false,
      modePresenter.showCount == 2
    else {
      throw SmokeFailure.expectation("Control + Shift + Space 没有切回中文模式")
    }
    guard
      !controller.handle(
        flags(code: 62, modifiers: [.control], timestamp: 2), client: client),
      !controller.handle(key("c", code: 8, modifiers: .control), client: client),
      !controller.handle(flags(code: 62, modifiers: [], timestamp: 2.1), client: client),
      modePresenter.showCount == 2
    else {
      throw SmokeFailure.expectation("右 Control 快捷键结束后错误切换了输入模式")
    }
    guard controller.handle(key("n", code: 45), client: client), !client.marked.isEmpty,
      controller.handle(
        key(" ", code: 49, modifiers: [.control, .shift]), client: client),
      client.marked.isEmpty,
      presenter.candidates.isEmpty,
      modePresenter.directMode == true,
      controller.handle(
        key(" ", code: 49, modifiers: [.control, .shift]), client: client),
      modePresenter.directMode == false
    else {
      throw SmokeFailure.expectation("组合过程中切换模式没有清除预编辑和候选")
    }

    guard controller.selectInputScheme(.flypy, for: client), client.marked.isEmpty,
      presenter.candidates.isEmpty
    else {
      throw SmokeFailure.expectation("切换小鹤双拼时没有清除组合状态")
    }
    let flypyMenu = controller.menu()
    guard flypyMenu?.item(withTitle: "全拼")?.state == .off,
      flypyMenu?.item(withTitle: "小鹤双拼")?.state == .on
    else {
      throw SmokeFailure.expectation("输入法菜单没有标记当前小鹤双拼方案")
    }
    for character in "uijp" {
      guard controller.handle(key(String(character), code: 0), client: client) else {
        throw SmokeFailure.expectation("小鹤双拼按键没有被处理：\(character)")
      }
    }
    guard (controller.candidates(client) as? [String])?.contains("世界") == true else {
      throw SmokeFailure.expectation("小鹤双拼 uijp 的候选中缺少“世界”")
    }
    guard controller.handle(key("", code: 53), client: client) else {
      throw SmokeFailure.expectation("小鹤双拼组合无法取消")
    }
    guard
      controller.handle(
        key(" ", code: 49, modifiers: [.control, .shift]), client: client),
      controller.selectInputScheme(.fullPinyin, for: client),
      !controller.handle(key("n", code: 45), client: client),
      controller.handle(
        key(" ", code: 49, modifiers: [.control, .shift]), client: client)
    else {
      throw SmokeFailure.expectation("切换输入方案意外改变了中英文模式")
    }

    for (character, keyCode) in zip("shijie", [1, 4, 34, 38, 34, 14]) {
      guard controller.handle(key(String(character), code: UInt16(keyCode)), client: client) else {
        throw SmokeFailure.expectation("拼音按键没有被处理：\(character)")
      }
    }
    let updateCountBeforePaging = presenter.updateCount
    guard controller.handle(key("", code: 121, modifiers: .function), client: client) else {
      throw SmokeFailure.expectation("Page Down 没有触发候选下一页")
    }
    guard presenter.updateCount > updateCountBeforePaging else {
      throw SmokeFailure.expectation("Page Down 翻页没有刷新候选窗口")
    }
    let updateCountBeforePreviousPage = presenter.updateCount
    guard controller.handle(key("", code: 123, modifiers: .function), client: client) else {
      throw SmokeFailure.expectation("向左键没有触发候选上一页")
    }
    guard presenter.updateCount > updateCountBeforePreviousPage else {
      throw SmokeFailure.expectation("向左翻页没有刷新候选窗口")
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

    for (character, keyCode) in zip("shijie", [1, 4, 34, 38, 34, 14]) {
      guard controller.handle(key(String(character), code: UInt16(keyCode)), client: client) else {
        throw SmokeFailure.expectation("全词候选测试无法输入拼音：\(character)")
      }
    }
    let compactCount = presenter.candidates.count
    guard controller.handle(key("", code: 124, modifiers: .function), client: client) else {
      throw SmokeFailure.expectation("紧凑候选窗的向右键没有展开全词候选窗")
    }
    guard presenter.expanded, presenter.candidates.count > compactCount else {
      throw SmokeFailure.expectation("全词候选窗没有加载当前页之外的候选")
    }
    let expandedPageSize = compactCount * CandidateWindowStyle.expandedColumnCount
    guard presenter.candidates.count == expandedPageSize else {
      throw SmokeFailure.expectation(
        "全词候选首次加载了 \(presenter.candidates.count) 项，而不是完整一页 \(expandedPageSize) 项"
      )
    }
    guard presenter.expandedHasMore, let expandedStart = presenter.highlighted else {
      throw SmokeFailure.expectation("全词候选翻页测试需要至少两页候选")
    }
    let firstExpandedPage = presenter.candidates
    let startingColumn = expandedStart / compactCount
    for _ in startingColumn..<CandidateWindowStyle.expandedColumnCount {
      guard controller.handle(key("", code: 124, modifiers: .function), client: client) else {
        throw SmokeFailure.expectation("全词候选窗无法向右移动到下一页")
      }
    }
    guard presenter.highlighted != expandedStart,
      presenter.candidates.count > firstExpandedPage.count,
      Array(presenter.candidates.prefix(firstExpandedPage.count)) == firstExpandedPage
    else {
      throw SmokeFailure.expectation("全词候选翻页后改变了已加载候选的位置")
    }
    let appendedCount = presenter.candidates.count - firstExpandedPage.count
    guard !presenter.expandedHasMore || appendedCount == expandedPageSize else {
      throw SmokeFailure.expectation(
        "全词候选后续只加载了 \(appendedCount) 项，而不是完整一页 \(expandedPageSize) 项"
      )
    }
    guard !controller.handle(key("\t", code: 48), client: client), presenter.expanded else {
      throw SmokeFailure.expectation("Tab 不应被用于关闭全词候选窗")
    }
    guard controller.handle(key("", code: 53), client: client), !presenter.expanded,
      presenter.candidates.isEmpty, client.marked.isEmpty
    else {
      throw SmokeFailure.expectation("Esc 没有取消组合并关闭全词候选窗")
    }
    for (character, keyCode) in zip("shijie", [1, 4, 34, 38, 34, 14]) {
      guard controller.handle(key(String(character), code: UInt16(keyCode)), client: client) else {
        throw SmokeFailure.expectation("Esc 取消后无法重新输入拼音：\(character)")
      }
    }
    guard controller.handle(key("", code: 124, modifiers: .function), client: client),
      presenter.expanded
    else {
      throw SmokeFailure.expectation("Esc 取消后新的组合不能展开全词候选窗")
    }
    guard controller.handle(key("", code: 124, modifiers: .function), client: client) else {
      throw SmokeFailure.expectation("数字选词前无法切换到下一列")
    }
    let expandedSelection = presenter.candidates[compactCount]
    guard controller.handle(key("1", code: 18), client: client) else {
      throw SmokeFailure.expectation("数字键没有选择当前列对应位置的候选")
    }
    guard client.committed.hasSuffix(expandedSelection.text), !presenter.expanded else {
      throw SmokeFailure.expectation("数字键没有按当前列的不透明候选 ID 上屏")
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
    try verifySharedCandidatePanelCount()
  }

  @MainActor
  private static func verifyCandidateOverlayOwnership() throws {
    let presenter = SmokeCandidatePresenter()
    let store = CandidateOverlayStore(presenter: presenter)
    let first = OwnedCandidatePresenter(store: store)
    let second = OwnedCandidatePresenter(store: store)
    let firstCandidate = FeatherCandidateValue(revision: 1, value: 1, text: "你好")
    let secondCandidate = FeatherCandidateValue(revision: 2, value: 2, text: "世界")
    var firstSelectionCount = 0
    var secondSelectionCount = 0

    first.activate()
    first.actionHandler = { _ in firstSelectionCount += 1 }
    first.update(candidates: [firstCandidate], highlighted: 0, anchor: .zero)

    second.activate()
    second.actionHandler = { _ in secondSelectionCount += 1 }
    second.update(candidates: [secondCandidate], highlighted: 0, anchor: .zero)

    first.actionHandler = nil
    first.hide()
    first.deactivate()
    presenter.select(text: "世界")
    guard
      presenter.candidates == [secondCandidate],
      firstSelectionCount == 0,
      secondSelectionCount == 1
    else {
      throw SmokeFailure.expectation("旧控制器修改了新控制器持有的共享候选窗")
    }

    second.deactivate()
    guard presenter.candidates.isEmpty else {
      throw SmokeFailure.expectation("当前控制器释放后共享候选窗没有隐藏")
    }
  }

  private static func verifyInputModeMemory() throws {
    let suiteName = "FeatherInputModeMemory-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      throw SmokeFailure.expectation("无法创建输入模式记忆测试设置")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(InputModeMemoryPolicy.perApplication.rawValue, forKey: "inputModeMemoryPolicy")
    let memory = InputModeMemory(defaults: defaults)
    guard !memory.activate(application: "app.one") else {
      throw SmokeFailure.expectation("新应用不应默认进入英文模式")
    }
    memory.update(directMode: true, application: "app.one")
    guard !memory.activate(application: "app.two"), memory.activate(application: "app.one") else {
      throw SmokeFailure.expectation("没有按应用保存中英文模式")
    }
  }

  private static func verifyInputSchemeMemory() throws {
    let suiteName = "FeatherInputSchemeMemory-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      throw SmokeFailure.expectation("无法创建输入方案记忆测试设置")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let memory = InputSchemeMemory(defaults: defaults)
    guard memory.load() == .fullPinyin else {
      throw SmokeFailure.expectation("新设置没有默认使用全拼")
    }
    memory.update(.flypy)
    guard memory.load() == .flypy else {
      throw SmokeFailure.expectation("没有持久化小鹤双拼方案")
    }
  }

  @MainActor
  private static func verifyModeIndicatorOwnership() throws {
    let presenter = SmokeModePresenter()
    let store = ModeIndicatorOverlayStore(presenter: presenter)
    let first = OwnedModeIndicatorPresenter(store: store)
    let second = OwnedModeIndicatorPresenter(store: store)

    first.activate()
    first.show(directMode: true, anchor: .zero, clientLevel: 0)
    second.activate()
    second.show(directMode: false, anchor: .zero, clientLevel: 0)
    first.hide()
    first.deactivate()

    guard presenter.isVisible, presenter.directMode == false else {
      throw SmokeFailure.expectation("旧控制器修改了新控制器持有的模式提示窗口")
    }
    second.deactivate()
    guard !presenter.isVisible else {
      throw SmokeFailure.expectation("当前控制器释放后模式提示窗口没有隐藏")
    }
  }

  @MainActor
  private static func verifySharedCandidatePanelCount() throws {
    let baseline = NSApplication.shared.windows.filter { $0 is NSPanel }.count
    var controllers: [InputController] = []

    for _ in 0..<12 {
      guard let controller = InputController(server: nil, delegate: nil, client: nil) else {
        throw SmokeFailure.controllerCreation
      }
      controller.secureInputEnabled = { false }
      let client = SmokeTextClient()
      controller.activateServer(client)
      for (character, keyCode) in zip("ni", [45, 34]) {
        guard controller.handle(key(String(character), code: UInt16(keyCode)), client: client)
        else {
          throw SmokeFailure.expectation("共享候选窗测试无法输入拼音")
        }
      }
      controller.deactivateServer(client)
      controllers.append(controller)
    }

    let finalCount = NSApplication.shared.windows.filter { $0 is NSPanel }.count
    guard finalCount <= baseline + 2 else {
      throw SmokeFailure.expectation(
        "多个输入控制器创建了 \(finalCount - baseline) 个输入浮层"
      )
    }
    withExtendedLifetime(controllers) {}
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

  private static func flags(
    code: UInt16,
    modifiers: NSEvent.ModifierFlags,
    timestamp: TimeInterval
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .flagsChanged,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: timestamp,
      windowNumber: 0,
      context: nil,
      characters: "",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: code
    )!
  }
}
