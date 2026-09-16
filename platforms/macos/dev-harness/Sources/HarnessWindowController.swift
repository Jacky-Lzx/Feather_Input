import AppKit

@MainActor
final class HarnessWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate
{
  private let session: FeatherSession
  private let captureView = KeyCaptureView()
  private let outputView = NSTextView()
  private let preeditLabel = NSTextField(labelWithString: "")
  private let stateLabel = NSTextField(labelWithString: "")
  private let tableView = NSTableView()
  private var currentResponse: FeatherResponseValue?

  init(session: FeatherSession, sharedData: URL, userData: URL, schema: String) {
    self.session = session
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 880, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Feather Input Rust Dev Harness"
    window.minSize = NSSize(width: 680, height: 520)
    window.center()
    super.init(window: window)

    buildInterface(sharedData: sharedData, userData: userData, schema: schema)
    captureView.eventHandler = { [weak self] event in
      self?.handle(event) ?? false
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) 未实现")
  }

  func start() throws {
    apply(try session.activate(), operation: "activate")
    window?.makeKeyAndOrderFront(nil)
    window?.makeFirstResponder(captureView)
  }

  func shutdown() {
    _ = try? session.deactivate()
    session.close()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    currentResponse?.candidates.count ?? 0
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard let candidate = currentResponse?.candidates[row], let identifier = tableColumn?.identifier
    else { return nil }
    let cell = NSTextField(labelWithString: "")
    cell.lineBreakMode = .byTruncatingTail
    switch identifier.rawValue {
    case "number":
      cell.stringValue = String(row + 1)
      cell.alignment = .right
      cell.textColor = .secondaryLabelColor
    case "candidate":
      cell.stringValue = candidate.text
      cell.font = .systemFont(ofSize: 16)
    default:
      cell.stringValue = "r\(candidate.revision) · id \(candidate.value)"
      cell.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
      cell.textColor = .secondaryLabelColor
    }
    return cell
  }

  @objc private func candidateClicked() {
    let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
    guard let response = currentResponse, response.candidates.indices.contains(row) else { return }
    dispatch("select \(row + 1)") { try session.select(response.candidates[row]) }
    window?.makeFirstResponder(captureView)
  }

  private func buildInterface(sharedData: URL, userData: URL, schema: String) {
    guard let contentView = window?.contentView else { return }

    let title = NSTextField(labelWithString: "Feather Input Rust 调试壳")
    title.font = .systemFont(ofSize: 24, weight: .bold)

    let paths = NSTextField(
      wrappingLabelWithString:
        "schema: \(schema)\n共享数据（只读副本）：\(sharedData.path)\n独立用户数据：\(userData.path)"
    )
    paths.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    paths.textColor = .secondaryLabelColor

    captureView.translatesAutoresizingMaskIntoConstraints = false
    captureView.heightAnchor.constraint(equalToConstant: 70).isActive = true

    let outputTitle = sectionTitle("已提交文本")
    outputView.isEditable = false
    outputView.isRichText = false
    outputView.font = .systemFont(ofSize: 18)
    outputView.drawsBackground = true
    outputView.backgroundColor = .textBackgroundColor
    outputView.textColor = .labelColor
    outputView.insertionPointColor = .labelColor
    outputView.textContainerInset = NSSize(width: 8, height: 8)
    let outputScroll = NSScrollView()
    outputScroll.documentView = outputView
    outputScroll.hasVerticalScroller = true
    outputScroll.borderType = .bezelBorder
    outputScroll.translatesAutoresizingMaskIntoConstraints = false
    outputScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

    let preeditTitle = sectionTitle("预编辑")
    preeditLabel.font = .monospacedSystemFont(ofSize: 20, weight: .medium)
    preeditLabel.lineBreakMode = .byTruncatingTail
    preeditLabel.placeholderString = "尚未开始组合"

    stateLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    stateLabel.textColor = .secondaryLabelColor

    let candidateTitle = sectionTitle("候选（单击选择）")
    addColumn(identifier: "number", title: "#", width: 44)
    addColumn(identifier: "candidate", title: "候选", width: 360)
    addColumn(identifier: "identity", title: "稳定身份", width: 260)
    tableView.headerView = NSTableHeaderView()
    tableView.rowHeight = 28
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.action = #selector(candidateClicked)

    let candidateScroll = NSScrollView()
    candidateScroll.documentView = tableView
    candidateScroll.hasVerticalScroller = true
    candidateScroll.borderType = .bezelBorder

    let stack = NSStackView(views: [
      title,
      paths,
      captureView,
      outputTitle,
      outputScroll,
      preeditTitle,
      preeditLabel,
      stateLabel,
      candidateTitle,
      candidateScroll,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.setCustomSpacing(16, after: paths)
    stack.setCustomSpacing(14, after: outputScroll)
    stack.setCustomSpacing(14, after: stateLabel)
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)

    candidateScroll.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
      captureView.widthAnchor.constraint(equalTo: stack.widthAnchor),
      outputScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
      preeditLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
      stateLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
      candidateScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
  }

  private func sectionTitle(_ value: String) -> NSTextField {
    let label = NSTextField(labelWithString: value)
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    return label
  }

  private func addColumn(identifier: String, title: String, width: CGFloat) {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
    column.title = title
    column.width = width
    tableView.addTableColumn(column)
  }

  private func handle(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.control), event.charactersIgnoringModifiers == " " {
      dispatch("toggle mode") { try session.send(.toggleMode) }
      return true
    }

    let special: FeatherKey? =
      switch event.keyCode {
      case 51: .backspace
      case 117: .delete
      case 49: .space
      case 36, 76: .enter
      case 53: .escape
      case 123: .left
      case 124: .right
      case 125: .down
      case 126: .up
      case 116: .pageUp
      case 121: .pageDown
      default: nil
      }
    if let special {
      dispatch("key \(special)") { try session.send(special) }
      return true
    }

    guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
      let text = event.characters, !text.isEmpty,
      text.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control })
    else { return false }
    dispatch("text \(text)") { try session.send(text: text) }
    return true
  }

  private func dispatch(_ operation: String, call: () throws -> FeatherResponseValue) {
    do {
      let response = try call()
      apply(response, operation: operation)
      if !response.handled {
        appendDirectFallback(for: operation)
      }
    } catch {
      show(error)
    }
  }

  private func apply(_ response: FeatherResponseValue, operation: String) {
    currentResponse = response
    if let commit = response.commit {
      appendOutput(commit)
    }
    preeditLabel.stringValue = markedPreedit(response.preedit, cursorUTF8: response.cursorUTF8)
    let highlighted = response.highlighted.map { String($0 + 1) } ?? "无"
    stateLabel.stringValue =
      "\(operation) · handled=\(response.handled) · active=\(response.active) "
      + "· mode=\(response.directMode ? "直输" : "输入法") · revision=\(response.revision) "
      + "· cursor_utf8=\(response.cursorUTF8) · highlighted=\(highlighted)"
    tableView.reloadData()
    if let highlighted = response.highlighted,
      response.candidates.indices.contains(highlighted)
    {
      tableView.selectRowIndexes(IndexSet(integer: highlighted), byExtendingSelection: false)
      tableView.scrollRowToVisible(highlighted)
    } else {
      tableView.deselectAll(nil)
    }
  }

  private func appendDirectFallback(for operation: String) {
    guard currentResponse?.directMode == true, operation.hasPrefix("text ") else { return }
    appendOutput(String(operation.dropFirst(5)))
  }

  private func appendOutput(_ text: String) {
    outputView.textStorage?.append(
      NSAttributedString(
        string: text,
        attributes: [
          .font: NSFont.systemFont(ofSize: 18),
          .foregroundColor: NSColor.labelColor,
        ]
      )
    )
    outputView.scrollToEndOfDocument(nil)
  }

  private func markedPreedit(_ text: String, cursorUTF8: Int) -> String {
    guard !text.isEmpty else { return "" }
    let utf8 = text.utf8
    guard cursorUTF8 >= 0, cursorUTF8 <= utf8.count else { return text }
    let utf8Index = utf8.index(utf8.startIndex, offsetBy: cursorUTF8)
    guard let index = String.Index(utf8Index, within: text) else { return text }
    return String(text[..<index]) + "│" + String(text[index...])
  }

  private func show(_ error: Error) {
    stateLabel.stringValue = error.localizedDescription
    stateLabel.textColor = .systemRed
  }
}
