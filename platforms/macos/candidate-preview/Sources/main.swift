import AppKit

struct FeatherCandidateValue: Equatable {
  let revision: UInt64
  let value: UInt64
  let text: String
}

struct FeatherGeneratedCandidateValue: Equatable {
  let text: String
  let score: Double
}

@MainActor
private final class PreviewWindow: NSWindow {
  var keyHandler: ((NSEvent) -> Bool)?

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, keyHandler?(event) == true {
      return
    }
    super.sendEvent(event)
  }
}

@MainActor
private final class PreviewWindowController: NSWindowController, NSWindowDelegate {
  private enum Scenario: Int {
    case standard
    case longText
    case manyCandidates
  }

  private let candidatePresenter = CandidateWindowController()
  private let generatedPresenter = CandidateWindowController()
  private let anchorView = NSTextField(string: "shijie  |")
  private let statusLabel = NSTextField(labelWithString: "候选窗操作会显示在这里")
  private let appearanceControl = NSSegmentedControl(
    labels: ["跟随系统", "浅色", "深色"],
    trackingMode: .selectOne,
    target: nil,
    action: nil
  )
  private let layoutSettings = CandidateLayoutSettings.shared
  private let fontSettings = CandidateFontSettings.shared
  private let layoutControl = NSSegmentedControl(
    labels: CandidateLayout.allCases.map(\.title),
    trackingMode: .selectOne,
    target: nil,
    action: nil
  )
  private let scenarioControl = NSSegmentedControl(
    labels: ["常规", "长文本", "全词候选"],
    trackingMode: .selectOne,
    target: nil,
    action: nil
  )
  private let fontSizeSlider = NSSlider(
    value: Double(CandidateFontSettings.defaultSize),
    minValue: Double(CandidateFontSettings.minimumSize),
    maxValue: Double(CandidateFontSettings.maximumSize),
    target: nil,
    action: nil
  )
  private let fontSizeLabel = NSTextField(labelWithString: "")
  private var scenario = Scenario.standard
  private var pageIndex = 0
  private var highlightedIndex = 0
  private var expanded = false
  private var expandedLayout = CandidateLayout.vertical
  private var compositionActive = true
  private var currentCandidates: [FeatherCandidateValue] = []
  private let generatedCandidates = [
    FeatherGeneratedCandidateValue(text: "视界", score: -0.41),
    FeatherGeneratedCandidateValue(text: "诗界", score: -0.68),
    FeatherGeneratedCandidateValue(text: "世杰", score: -0.83),
  ]

  init() {
    let window = PreviewWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 470),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Feather 候选窗预览"
    window.minSize = NSSize(width: 620, height: 430)
    super.init(window: window)
    window.keyHandler = { [weak self] event in
      self?.handleKeyEvent(event) ?? false
    }
    window.delegate = self
    buildInterface(in: window)
    connectActions()
    window.center()
    candidatePresenter.actionHandler = { [weak self] action in
      self?.handle(action)
    }
    generatedPresenter.generatedActionHandler = { [weak self] index in
      self?.selectGeneratedCandidate(at: index, source: "点击")
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func showPreview() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    DispatchQueue.main.async { [weak self] in
      self?.refreshCandidates()
    }
  }

  func windowDidMove(_ notification: Notification) {
    refreshPosition()
  }

  func windowDidResize(_ notification: Notification) {
    refreshPosition()
  }

  func windowWillClose(_ notification: Notification) {
    candidatePresenter.hide()
    generatedPresenter.hide()
  }

  private func buildInterface(in window: NSWindow) {
    let content = NSView()
    window.contentView = content

    let title = NSTextField(labelWithString: "候选窗视觉验收")
    title.font = .systemFont(ofSize: 24, weight: .semibold)

    let help = NSTextField(
      wrappingLabelWithString:
        "这个程序只渲染候选窗，不链接输入法引擎，也不会安装、注册或切换系统输入源。窗口获得焦点后，可用与输入法相同的方向键、翻页键、数字键、空格、回车和 Esc 模拟操作；常规场景还可用 Option + 1/2/3 或 Option + Space 选择 AI 候选。"
    )
    help.font = .systemFont(ofSize: 13)
    help.textColor = .secondaryLabelColor

    appearanceControl.selectedSegment = 0
    layoutControl.selectedSegment =
      CandidateLayout.allCases.firstIndex(of: layoutSettings.layout) ?? 0
    scenarioControl.selectedSegment = 0
    fontSizeSlider.doubleValue = Double(fontSettings.size)
    fontSizeSlider.numberOfTickMarks =
      Int(CandidateFontSettings.maximumSize - CandidateFontSettings.minimumSize) + 1
    fontSizeSlider.allowsTickMarkValuesOnly = true
    fontSizeLabel.stringValue = "\(Int(fontSettings.size))"
    fontSizeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    let fontSizeControls = NSStackView(views: [fontSizeSlider, fontSizeLabel])
    fontSizeControls.orientation = .horizontal
    fontSizeControls.alignment = .centerY
    fontSizeControls.spacing = 8

    let appearanceRow = formRow(title: "外观", control: appearanceControl)
    let layoutRow = formRow(title: "排列", control: layoutControl)
    let fontSizeRow = formRow(title: "字号", control: fontSizeControls)
    let scenarioRow = formRow(title: "内容", control: scenarioControl)

    let previous = NSButton(title: "上一项", target: self, action: #selector(highlightPrevious(_:)))
    let next = NSButton(title: "下一项", target: self, action: #selector(highlightNext(_:)))
    let highlightRow = NSStackView(views: [previous, next])
    highlightRow.orientation = .horizontal
    highlightRow.spacing = 8

    anchorView.font = .monospacedSystemFont(ofSize: 20, weight: .regular)
    anchorView.isEditable = false
    anchorView.isSelectable = false
    anchorView.alignment = .left
    anchorView.drawsBackground = true
    anchorView.backgroundColor = .textBackgroundColor
    anchorView.heightAnchor.constraint(equalToConstant: 44).isActive = true

    let anchorHelp = NSTextField(
      labelWithString: "候选窗会锚定在下面模拟的插入点处；移动或缩放窗口时会自动跟随。"
    )
    anchorHelp.font = .systemFont(ofSize: 12)
    anchorHelp.textColor = .secondaryLabelColor

    statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    statusLabel.textColor = .secondaryLabelColor

    let stack = NSStackView(views: [
      title,
      help,
      appearanceRow,
      layoutRow,
      fontSizeRow,
      scenarioRow,
      highlightRow,
      anchorHelp,
      anchorView,
      statusLabel,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 13
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)

    help.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    appearanceRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    layoutRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    fontSizeRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    scenarioRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    anchorView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
    ])
  }

  private func formRow(title: String, control: NSView) -> NSStackView {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.widthAnchor.constraint(equalToConstant: 48).isActive = true
    let row = NSStackView(views: [label, control, NSView()])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    return row
  }

  private func connectActions() {
    appearanceControl.target = self
    appearanceControl.action = #selector(changeAppearance(_:))
    layoutControl.target = self
    layoutControl.action = #selector(changeLayout(_:))
    scenarioControl.target = self
    scenarioControl.action = #selector(changeScenario(_:))
    fontSizeSlider.target = self
    fontSizeSlider.action = #selector(changeFontSize(_:))
  }

  @objc private func changeAppearance(_ sender: NSSegmentedControl) {
    switch sender.selectedSegment {
    case 1:
      NSApplication.shared.appearance = NSAppearance(named: .aqua)
    case 2:
      NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    default:
      NSApplication.shared.appearance = nil
    }
    refreshCandidates()
  }

  @objc private func changeLayout(_ sender: NSSegmentedControl) {
    guard CandidateLayout.allCases.indices.contains(sender.selectedSegment) else { return }
    layoutSettings.update(CandidateLayout.allCases[sender.selectedSegment])
    if expanded {
      expandedLayout = layoutSettings.layout
    }
    refreshCandidates()
  }

  @objc private func changeScenario(_ sender: NSSegmentedControl) {
    scenario = Scenario(rawValue: sender.selectedSegment) ?? .standard
    pageIndex = 0
    highlightedIndex = 0
    expanded = scenario == .manyCandidates
    expandedLayout = layoutSettings.layout
    compositionActive = true
    refreshCandidates()
  }

  @objc private func changeFontSize(_ sender: NSSlider) {
    fontSettings.updateSize(CGFloat(sender.doubleValue))
    fontSizeLabel.stringValue = "\(Int(fontSettings.size))"
    refreshCandidates()
  }

  @objc private func highlightPrevious(_ sender: Any?) {
    guard !currentCandidates.isEmpty else { return }
    highlightedIndex = max(0, highlightedIndex - 1)
    refreshCandidates()
  }

  @objc private func highlightNext(_ sender: Any?) {
    guard !currentCandidates.isEmpty else { return }
    highlightedIndex = min(currentCandidates.count - 1, highlightedIndex + 1)
    refreshCandidates()
  }

  private func handle(_ action: CandidateWindowAction) {
    switch action {
    case .select(let candidate):
      statusLabel.stringValue = "已点击候选：\(candidate.text)"
      if let index = currentCandidates.firstIndex(of: candidate) {
        highlightedIndex = index
      }
    case .pageUp:
      pageIndex = max(0, pageIndex - 1)
      highlightedIndex = 0
      statusLabel.stringValue = "已触发上一页"
    case .pageDown:
      pageIndex = min(pages.count - 1, pageIndex + 1)
      highlightedIndex = 0
      statusLabel.stringValue = "已触发下一页"
    }
    refreshCandidates()
  }

  private func handleKeyEvent(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if modifiers == .option, generatedPresenter.isVisible {
      let index: Int?
      switch event.keyCode {
      case 18, 83, 49: index = 0
      case 19, 84: index = 1
      case 20, 85: index = 2
      default: index = nil
      }
      guard let index else { return false }
      selectGeneratedCandidate(at: index, source: "快捷键")
      return true
    }
    guard modifiers.isEmpty else {
      return false
    }
    guard compositionActive else { return false }
    if expanded {
      return handleExpandedKeyEvent(event)
    }

    switch candidatePresenter.compactLayout {
    case .vertical:
      switch event.keyCode {
      case 123, 116:
        pageIndex = max(0, pageIndex - 1)
        highlightedIndex = 0
        statusLabel.stringValue = "模拟上一页"
      case 121:
        pageIndex = min(pages.count - 1, pageIndex + 1)
        highlightedIndex = 0
        statusLabel.stringValue = "模拟下一页"
      case 124:
        expanded = true
        expandedLayout = .vertical
        highlightedIndex = pageIndex * 5
        statusLabel.stringValue = "已用右方向键展开全词候选"
      case 125:
        highlightedIndex = min(currentCandidates.count - 1, highlightedIndex + 1)
        statusLabel.stringValue = "模拟下一项"
      case 126:
        highlightedIndex = max(0, highlightedIndex - 1)
        statusLabel.stringValue = "模拟上一项"
      default:
        return false
      }
    case .horizontal:
      switch event.keyCode {
      case 123:
        highlightedIndex = max(0, highlightedIndex - 1)
        statusLabel.stringValue = "模拟上一项"
      case 124:
        highlightedIndex = min(currentCandidates.count - 1, highlightedIndex + 1)
        statusLabel.stringValue = "模拟下一项"
      case 125, 126:
        expanded = true
        expandedLayout = .horizontal
        highlightedIndex = pageIndex * 5
        statusLabel.stringValue = "已用上下方向键展开全词候选"
      case 116:
        pageIndex = max(0, pageIndex - 1)
        highlightedIndex = 0
        statusLabel.stringValue = "模拟上一页"
      case 121:
        pageIndex = min(pages.count - 1, pageIndex + 1)
        highlightedIndex = 0
        statusLabel.stringValue = "模拟下一页"
      default:
        return false
      }
    }
    refreshCandidates()
    return true
  }

  private func handleExpandedKeyEvent(_ event: NSEvent) -> Bool {
    if event.keyCode == 48 {
      return false
    }
    if event.keyCode == 53 {
      expanded = false
      compositionActive = false
      currentCandidates = []
      candidatePresenter.hide()
      statusLabel.stringValue = "已用 Esc 取消本次输入并关闭候选窗"
      return true
    }
    if event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76 {
      selectHighlightedCandidate()
      return true
    }
    if let characters = event.charactersIgnoringModifiers,
      let number = Int(characters), (1...5).contains(number)
    {
      let index = highlightedIndex / 5 * 5 + number - 1
      if currentCandidates.indices.contains(index) {
        highlightedIndex = index
        selectHighlightedCandidate()
      }
      return true
    }

    let movement: (horizontal: Int, vertical: Int)
    switch event.keyCode {
    case 123: movement = (-1, 0)
    case 124: movement = (1, 0)
    case 125: movement = (0, 1)
    case 126: movement = (0, -1)
    default: return false
    }
    moveExpandedHighlight(horizontal: movement.horizontal, vertical: movement.vertical)
    statusLabel.stringValue = "已模拟全词候选方向键导航"
    refreshCandidates()
    return true
  }

  private func moveExpandedHighlight(horizontal: Int, vertical: Int) {
    guard !currentCandidates.isEmpty else { return }
    let pageSize = 5
    switch expandedLayout {
    case .vertical:
      let currentColumn = highlightedIndex / pageSize
      let maximumColumn = (currentCandidates.count - 1) / pageSize
      let column = min(maximumColumn, max(0, currentColumn + horizontal))
      let currentRow = highlightedIndex % pageSize
      let maximumRow = min(pageSize - 1, currentCandidates.count - 1 - column * pageSize)
      let row = min(maximumRow, max(0, currentRow + vertical))
      highlightedIndex = column * pageSize + row
    case .horizontal:
      let currentRow = highlightedIndex / pageSize
      let maximumRow = (currentCandidates.count - 1) / pageSize
      let row = min(maximumRow, max(0, currentRow + vertical))
      let currentColumn = highlightedIndex % pageSize
      let maximumColumn = min(pageSize - 1, currentCandidates.count - 1 - row * pageSize)
      let column = min(maximumColumn, max(0, currentColumn + horizontal))
      highlightedIndex = row * pageSize + column
    }
  }

  private func selectHighlightedCandidate() {
    guard currentCandidates.indices.contains(highlightedIndex) else { return }
    statusLabel.stringValue = "模拟选择：\(currentCandidates[highlightedIndex].text)"
  }

  private func refreshCandidates() {
    guard window?.isVisible == true else { return }
    guard compositionActive else {
      candidatePresenter.hide()
      generatedPresenter.hide()
      currentCandidates = []
      return
    }
    let availablePages = pages
    pageIndex = min(pageIndex, availablePages.count - 1)
    currentCandidates = makeCandidates(
      expanded ? availablePages.flatMap { $0 } : availablePages[pageIndex])
    highlightedIndex = min(highlightedIndex, currentCandidates.count - 1)
    if expanded {
      candidatePresenter.updateExpanded(
        candidates: currentCandidates,
        highlighted: highlightedIndex,
        pageSize: 5,
        layout: expandedLayout,
        hasMore: false,
        preedit: "shijie",
        anchor: anchorRectOnScreen()
      )
    } else {
      candidatePresenter.update(
        candidates: currentCandidates,
        highlighted: highlightedIndex,
        preedit: "shijie",
        anchor: anchorRectOnScreen()
      )
    }
    refreshGeneratedCandidates()
  }

  private func refreshPosition() {
    guard !currentCandidates.isEmpty, window?.isVisible == true else { return }
    if expanded {
      candidatePresenter.updateExpanded(
        candidates: currentCandidates,
        highlighted: highlightedIndex,
        pageSize: 5,
        layout: expandedLayout,
        hasMore: false,
        preedit: "shijie",
        anchor: anchorRectOnScreen()
      )
    } else {
      candidatePresenter.update(
        candidates: currentCandidates,
        highlighted: highlightedIndex,
        preedit: "shijie",
        anchor: anchorRectOnScreen()
      )
    }
    refreshGeneratedCandidates()
  }

  private func refreshGeneratedCandidates() {
    guard scenario == .standard, !expanded, compositionActive else {
      generatedPresenter.hide()
      return
    }
    generatedPresenter.update(
      candidates: generatedCandidates,
      beside: candidatePresenter.frame,
      title: nil
    )
  }

  private func selectGeneratedCandidate(at index: Int, source: String) {
    guard generatedCandidates.indices.contains(index), generatedPresenter.isVisible else { return }
    statusLabel.stringValue = "已用\(source)选择 AI 候选：\(generatedCandidates[index].text)"
    compositionActive = false
    currentCandidates = []
    candidatePresenter.hide()
    generatedPresenter.hide()
  }

  private func anchorRectOnScreen() -> NSRect {
    guard let window else { return .zero }
    let localRect = anchorView.convert(anchorView.bounds, to: nil)
    let fieldRect = window.convertToScreen(localRect)
    return NSRect(x: fieldRect.minX + 82, y: fieldRect.minY + 8, width: 2, height: 24)
  }

  private func makeCandidates(_ texts: [String]) -> [FeatherCandidateValue] {
    texts.enumerated().map { index, text in
      FeatherCandidateValue(revision: 1, value: UInt64(index + 1), text: text)
    }
  }

  private var pages: [[String]] {
    switch scenario {
    case .standard, .manyCandidates:
      return stride(from: 0, to: allCandidates.count, by: 5).map {
        Array(allCandidates[$0..<min($0 + 5, allCandidates.count)])
      }
    case .longText:
      return [
        [
          "世界",
          "这是一条用于检查候选文本过长时尾部截断效果的候选内容",
          "Feather Input Method Candidate Window",
          "深色模式和浅色模式都应保持清晰",
        ]
      ]
    }
  }

  private var allCandidates: [String] {
    [
      "世界", "时间", "实践", "世间", "事件", "视界", "始建", "诗笺", "试件", "市建",
      "诗界", "识解", "是借", "石阶", "时节", "史界", "实结", "视角", "拾芥", "释解",
      "世杰", "石介", "食街", "失节", "事捷", "试解", "时捷", "识界", "实价", "市街",
    ]
  }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
  private var controller: PreviewWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = PreviewWindowController()
    self.controller = controller
    controller.showPreview()
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

@main
private enum FeatherCandidatePreviewMain {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) {
      application.run()
    }
  }
}
