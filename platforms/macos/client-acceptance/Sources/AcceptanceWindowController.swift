import AppKit

@MainActor
final class AcceptanceWindowController: NSWindowController {
  private let textView = ShortcutTextView()
  private let secureField = NSSecureTextField()
  private let compositionStatus = NSTextField(labelWithString: "尚未输入")
  private let clientEventStatus = NSTextField(labelWithString: "尚未收到客户端按键")
  private let progressStatus = NSTextField(labelWithString: "0 / 14 项已确认")
  private var checks: [NSButton] = []

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Feather Input Rust Dev 客户端验收"
    window.minSize = NSSize(width: 820, height: 700)
    super.init(window: window)
    buildInterface(in: window)
    installMenu()
    window.center()
    window.makeFirstResponder(textView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func textDidChange(_ notification: Notification) {
    let marked = textView.markedRange()
    let markedDescription =
      marked.location == NSNotFound
      ? "无预编辑"
      : "预编辑范围 UTF-16: \(marked.location)..<\(marked.location + marked.length)"
    compositionStatus.stringValue =
      "正文长度 UTF-16: \(textView.string.utf16.count)；\(markedDescription)"
  }

  @objc private func resetFields(_ sender: Any?) {
    textView.string = ""
    secureField.stringValue = ""
    compositionStatus.stringValue = "已清空"
    window?.makeFirstResponder(textView)
  }

  @objc private func recordMenuShortcut(_ sender: Any?) {
    clientEventStatus.stringValue = "客户端收到按键：Command + Option + K"
  }

  @objc private func updateProgress(_ sender: NSButton) {
    let completed = checks.filter { $0.state == .on }.count
    progressStatus.stringValue = "\(completed) / \(checks.count) 项已确认"
  }

  private func buildInterface(in window: NSWindow) {
    let content = NSView()
    window.contentView = content

    let title = label(
      "普通 AppKit 文本客户端",
      font: .systemFont(ofSize: 24, weight: .semibold)
    )
    let instructions = label(
      "先从菜单栏切换到 Feather Rust Dev。用全拼输入 shijie、用小鹤双拼输入 uijp，确认都能得到“世界”；输入 shi 检查全词候选。单击右 Control 或按 Control + Shift + Space 检查中英文切换。这个应用不链接 Rust 或 librime。",
      font: .systemFont(ofSize: 14)
    )
    instructions.textColor = .secondaryLabelColor

    textView.font = .systemFont(ofSize: 22)
    textView.isRichText = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.clientEventHandler = { [weak self] description in
      self?.clientEventStatus.stringValue = "客户端收到按键：\(description)"
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(textDidChange(_:)),
      name: NSText.didChangeNotification,
      object: textView
    )

    let scrollView = NSScrollView()
    scrollView.borderType = .bezelBorder
    scrollView.hasVerticalScroller = true
    scrollView.documentView = textView
    scrollView.heightAnchor.constraint(equalToConstant: 150).isActive = true

    compositionStatus.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    compositionStatus.textColor = .secondaryLabelColor

    let secureTitle = label("安全输入检查", font: .systemFont(ofSize: 16, weight: .medium))
    secureField.placeholderString = "在这里输入时不应出现预编辑或候选窗口"
    secureField.font = .systemFont(ofSize: 16)

    let clientEventTitle = label(
      "客户端按键检查", font: .systemFont(ofSize: 16, weight: .medium))
    let clientEventHelp = label(
      "在普通文本框中按 Tab、Control + K、Option + K 或 Command + Option + K。若输入法放行，下面会显示对应按键。",
      font: .systemFont(ofSize: 13)
    )
    clientEventHelp.textColor = .secondaryLabelColor
    clientEventStatus.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

    let checklistTitle = label("人工验收清单", font: .systemFont(ofSize: 16, weight: .medium))
    let checklistItems = [
      "shijie 出现预编辑和“世界”候选",
      "紧凑窗上下键会改变候选高亮",
      "紧凑窗左键和 Page Up / Page Down 会翻页",
      "紧凑窗右键会展开全词候选",
      "全词窗四个方向键可以跨行、跨列移动",
      "全词窗只有当前列显示数字",
      "数字键选择当前列对应候选并上屏",
      "Tab 由客户端接收，输入法不主动关闭全词候选",
      "Esc 取消组合并关闭候选窗，不产生上屏文字",
      "输入 shi，右移越过第 40 项后仍能继续加载候选",
      "空格、回车和鼠标点击均能上屏",
      "客户端能够收到 Command / Control / Option 快捷键",
      "密码框中不出现预编辑或候选窗口",
      "浅色与深色模式下候选内容均清晰可见",
      "右 Control 单击会切换中英文并显示状态提示",
      "Control + Shift + Space 会切换模式并取消现有组合",
      "小鹤双拼输入 uijp 时出现“世界”候选",
      "输入方案切换不会改变当前中英文模式",
      "设置窗口会保存输入方案与模式记忆策略",
      "组合过程中打开设置不会意外上屏文字",
    ]
    let checklistColumns = [makeChecklistColumn(), makeChecklistColumn()]
    let itemsPerColumn = (checklistItems.count + 1) / 2
    for (index, item) in checklistItems.enumerated() {
      let button = NSButton(
        checkboxWithTitle: item, target: self, action: #selector(updateProgress(_:)))
      checks.append(button)
      checklistColumns[index / itemsPerColumn].addArrangedSubview(button)
    }
    let checklist = NSStackView(views: checklistColumns)
    checklist.orientation = .horizontal
    checklist.alignment = .top
    checklist.distribution = .fillEqually
    checklist.spacing = 18

    progressStatus.font = .systemFont(ofSize: 13, weight: .semibold)
    let reset = NSButton(title: "清空输入", target: self, action: #selector(resetFields(_:)))
    reset.bezelStyle = .rounded

    let footer = NSStackView(views: [progressStatus, NSView(), reset])
    footer.orientation = .horizontal
    footer.alignment = .centerY
    footer.distribution = .fill

    let stack = NSStackView(views: [
      title,
      instructions,
      scrollView,
      compositionStatus,
      secureTitle,
      secureField,
      clientEventTitle,
      clientEventHelp,
      clientEventStatus,
      checklistTitle,
      checklist,
      footer,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)

    instructions.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    secureField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    checklist.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22),
    ])
  }

  private func installMenu() {
    let mainMenu = NSMenu()
    let applicationItem = NSMenuItem()
    mainMenu.addItem(applicationItem)

    let applicationMenu = NSMenu()
    applicationMenu.addItem(
      withTitle: "退出客户端验收",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    applicationItem.submenu = applicationMenu

    let validationItem = NSMenuItem()
    mainMenu.addItem(validationItem)
    let validationMenu = NSMenu(title: "验收")
    let shortcut = NSMenuItem(
      title: "快捷键回显",
      action: #selector(recordMenuShortcut(_:)),
      keyEquivalent: "k"
    )
    shortcut.target = self
    shortcut.keyEquivalentModifierMask = [.command, .option]
    validationMenu.addItem(shortcut)
    validationItem.submenu = validationMenu
    NSApplication.shared.mainMenu = mainMenu
  }

  private func label(_ text: String, font: NSFont) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = font
    return label
  }

  private func makeChecklistColumn() -> NSStackView {
    let column = NSStackView()
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 4
    return column
  }
}

@MainActor
private final class ShortcutTextView: NSTextView {
  var clientEventHandler: ((String) -> Void)?

  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option])
    if !modifiers.isEmpty {
      var names: [String] = []
      if modifiers.contains(.command) { names.append("Command") }
      if modifiers.contains(.control) { names.append("Control") }
      if modifiers.contains(.option) { names.append("Option") }
      let key = event.charactersIgnoringModifiers?.uppercased() ?? "?"
      clientEventHandler?((names + [key]).joined(separator: " + "))
    }
    super.keyDown(with: event)
  }

  override func doCommand(by selector: Selector) {
    let command = NSStringFromSelector(selector)
    if command == "insertTab:" || command == "insertTabIgnoringFieldEditor:" {
      clientEventHandler?("Tab（\(command)）")
    }
    super.doCommand(by: selector)
  }
}
