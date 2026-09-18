import AppKit

@MainActor
private final class CandidateRowButton: NSButton {
  private let metrics: CandidateWindowMetrics
  private let indexLabel = NSTextField(labelWithString: "")
  private let candidateLabel = NSTextField(labelWithString: "")
  private var trackingArea: NSTrackingArea?
  private let interactionHandler: (() -> Void)?
  private var hovering = false {
    didSet { needsDisplay = true }
  }

  var candidateHighlighted = false {
    didSet { needsDisplay = true }
  }

  override init(frame frameRect: NSRect) {
    metrics = CandidateWindowStyle.metrics(fontSize: CandidateFontSettings.defaultSize)
    interactionHandler = nil
    super.init(frame: frameRect)
    configureView()
  }

  required init?(coder: NSCoder) {
    metrics = CandidateWindowStyle.metrics(fontSize: CandidateFontSettings.defaultSize)
    interactionHandler = nil
    super.init(coder: coder)
    configureView()
  }

  private init(metrics: CandidateWindowMetrics, interactionHandler: (() -> Void)?) {
    self.metrics = metrics
    self.interactionHandler = interactionHandler
    super.init(frame: .zero)
    configureView()
  }

  convenience init(
    index: String,
    text: String,
    metrics: CandidateWindowMetrics,
    target: AnyObject?,
    action: Selector?,
    interactionHandler: (() -> Void)? = nil
  ) {
    self.init(metrics: metrics, interactionHandler: interactionHandler)
    self.target = target
    self.action = action
    indexLabel.stringValue = index
    candidateLabel.stringValue = text
    setAccessibilityLabel(index.isEmpty ? "候选：\(text)" : "候选 \(index)：\(text)")
  }

  override var wantsUpdateLayer: Bool { true }

  override var intrinsicContentSize: NSSize {
    NSSize(
      width: CandidateWindowStyle.candidateHorizontalPadding * 2
        + metrics.indexWidth
        + CandidateWindowStyle.candidateLabelSpacing
        + candidateLabel.intrinsicContentSize.width,
      height: metrics.candidateHeight
    )
  }

  override func updateLayer() {
    super.updateLayer()
    guard let layer else { return }
    let darkAppearance =
      effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let background: NSColor
    if candidateHighlighted {
      background =
        darkAppearance
        ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
    } else if hovering {
      background = NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.55)
    } else {
      background = .clear
    }
    let foreground: NSColor =
      candidateHighlighted && darkAppearance ? .selectedControlTextColor : .labelColor
    layer.backgroundColor = background.cgColor
    layer.cornerRadius = CandidateWindowStyle.candidateCornerRadius
    indexLabel.textColor =
      candidateHighlighted ? foreground.withAlphaComponent(0.78) : .secondaryLabelColor
    candidateLabel.textColor = foreground
  }

  override func updateTrackingAreas() {
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    hovering = true
    interactionHandler?()
  }

  override func mouseExited(with event: NSEvent) {
    hovering = false
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  private func configureView() {
    title = ""
    isBordered = false
    setButtonType(.momentaryPushIn)
    focusRingType = .none
    wantsLayer = true

    indexLabel.alignment = .left
    indexLabel.font = metrics.indexFont
    indexLabel.lineBreakMode = .byClipping
    indexLabel.maximumNumberOfLines = 1
    candidateLabel.font = metrics.candidateFont
    candidateLabel.lineBreakMode = .byTruncatingTail
    candidateLabel.maximumNumberOfLines = 1
    candidateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    addSubview(indexLabel)
    addSubview(candidateLabel)
    indexLabel.translatesAutoresizingMaskIntoConstraints = false
    candidateLabel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: metrics.candidateHeight),
      indexLabel.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: CandidateWindowStyle.candidateHorizontalPadding
      ),
      indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      indexLabel.widthAnchor.constraint(equalToConstant: metrics.indexWidth),
      candidateLabel.leadingAnchor.constraint(
        equalTo: indexLabel.trailingAnchor,
        constant: CandidateWindowStyle.candidateLabelSpacing
      ),
      candidateLabel.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -CandidateWindowStyle.candidateHorizontalPadding
      ),
      candidateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }
}

@MainActor
private final class CandidateBackgroundView: NSVisualEffectView {
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    super.updateLayer()
    layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.52).cgColor
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

enum CandidateWindowAction {
  case select(FeatherCandidateValue)
  case pageUp
  case pageDown
}

@MainActor
protocol CandidatePresenting: AnyObject {
  var actionHandler: ((CandidateWindowAction) -> Void)? { get set }
  var interactionHandler: (() -> Void)? { get set }
  var compactLayout: CandidateLayout { get }
  var frame: NSRect { get }

  func update(
    candidates: [FeatherCandidateValue],
    highlighted: Int?,
    anchor: NSRect
  )
  func updateExpanded(
    candidates: [FeatherCandidateValue],
    highlighted: Int,
    pageSize: Int,
    layout: CandidateLayout,
    hasMore: Bool,
    anchor: NSRect
  )
  func setRerankingActive(_ active: Bool)
  func hide()
}

@MainActor
protocol GeneratedCandidatePresenting: AnyObject {
  var generatedActionHandler: ((Int) -> Void)? { get set }
  var isVisible: Bool { get }

  func update(candidates: [FeatherGeneratedCandidateValue], beside anchor: NSRect)
  func hide()
}

@MainActor
final class CandidateWindowController: NSObject, CandidatePresenting, GeneratedCandidatePresenting {
  var actionHandler: ((CandidateWindowAction) -> Void)?
  var interactionHandler: (() -> Void)?
  var generatedActionHandler: ((Int) -> Void)?
  private let layoutSettings: CandidateLayoutSettings
  private let fontSettings: CandidateFontSettings
  private(set) var resolvedCompactLayout = CandidateLayout.vertical
  private(set) var numberedExpandedIndices: [Int] = []
  private(set) var appliedFontSize = CandidateFontSettings.defaultSize
  private(set) var displayedGeneratedCandidateCount = 0
  var compactLayout: CandidateLayout { resolvedCompactLayout }
  var frame: NSRect { panel.frame }
  var currentPanelSize: NSSize { panel.frame.size }
  var isVisible: Bool { panel.isVisible }
  var isRerankingIndicatorVisible: Bool { !rerankingIndicator.isHidden }

  private var candidates: [FeatherCandidateValue] = []
  private var generatedCandidates: [FeatherGeneratedCandidateValue] = []
  private lazy var panel = makePanel()
  private lazy var candidateStack = makeCandidateStack()
  private lazy var expandedHeader = makeExpandedHeader()
  private var expandedHeaderHeightConstraint: NSLayoutConstraint?
  private lazy var expandedGrid = makeExpandedGrid()
  private lazy var contentStack = makeContentStack()
  private lazy var rerankingIndicator = makeRerankingIndicator()
  private lazy var backgroundView = makeBackgroundView()

  init(
    layoutSettings: CandidateLayoutSettings = .shared,
    fontSettings: CandidateFontSettings = .shared
  ) {
    self.layoutSettings = layoutSettings
    self.fontSettings = fontSettings
    super.init()
  }

  func update(
    candidates: [FeatherCandidateValue],
    highlighted: Int?,
    anchor: NSRect
  ) {
    guard !candidates.isEmpty else {
      hide()
      return
    }

    self.candidates = candidates
    generatedCandidates = []
    displayedGeneratedCandidateCount = 0
    appliedFontSize = fontSettings.size
    candidateStack.isHidden = false
    expandedHeader.isHidden = true
    expandedGrid.isHidden = true
    removeArrangedSubviews(from: expandedGrid)
    let contentWidth = rebuildCandidateRows(highlighted: highlighted, anchor: anchor)
    resizeAndShow(
      at: anchor,
      contentWidth: contentWidth,
      minimumWidth: CandidateWindowStyle.minimumCompactWidth
    )
  }

  func update(candidates: [FeatherGeneratedCandidateValue], beside anchor: NSRect) {
    guard !candidates.isEmpty else {
      hide()
      return
    }

    self.candidates = []
    generatedCandidates = Array(candidates.prefix(3))
    displayedGeneratedCandidateCount = generatedCandidates.count
    appliedFontSize = fontSettings.size
    candidateStack.isHidden = false
    expandedHeader.isHidden = true
    expandedGrid.isHidden = true
    removeArrangedSubviews(from: expandedGrid)
    let contentWidth = rebuildCandidateRows(highlighted: nil, anchor: anchor)
    resizeAndShow(beside: anchor, contentWidth: contentWidth, minimumWidth: 0)
  }

  func updateExpanded(
    candidates: [FeatherCandidateValue],
    highlighted: Int,
    pageSize: Int,
    layout: CandidateLayout,
    hasMore: Bool,
    anchor: NSRect
  ) {
    guard !candidates.isEmpty, pageSize > 0 else {
      hide()
      return
    }

    self.candidates = candidates
    generatedCandidates = []
    displayedGeneratedCandidateCount = 0
    appliedFontSize = fontSettings.size
    candidateStack.isHidden = true
    expandedHeader.isHidden = false
    expandedGrid.isHidden = false
    removeArrangedSubviews(from: candidateStack)
    expandedHeader.stringValue = "全部候选 · \(candidates.count)\(hasMore ? "+" : "")"
    expandedHeader.font = currentMetrics.expandedHeaderFont
    expandedHeaderHeightConstraint?.constant = currentMetrics.expandedHeaderHeight
    let gridWidth = rebuildExpandedGrid(
      highlighted: highlighted,
      pageSize: pageSize,
      layout: layout
    )
    let contentWidth = max(gridWidth, expandedHeader.intrinsicContentSize.width)
    resizeAndShow(at: anchor, contentWidth: contentWidth, minimumWidth: 0)
  }

  private func resizeAndShow(
    at anchor: NSRect,
    contentWidth: CGFloat,
    minimumWidth: CGFloat
  ) {
    resize(contentWidth: contentWidth, minimumWidth: minimumWidth)
    positionPanel(at: anchor)
    panel.orderFrontRegardless()
  }

  private func resizeAndShow(
    beside anchor: NSRect,
    contentWidth: CGFloat,
    minimumWidth: CGFloat
  ) {
    resize(contentWidth: contentWidth, minimumWidth: minimumWidth)
    positionPanel(beside: anchor)
    panel.orderFrontRegardless()
  }

  private func resize(contentWidth: CGFloat, minimumWidth: CGFloat) {
    panel.contentView = backgroundView
    backgroundView.layoutSubtreeIfNeeded()
    let fittingSize = backgroundView.fittingSize
    let horizontalInsets =
      CandidateWindowStyle.contentInsets.left + CandidateWindowStyle.contentInsets.right
    panel.setContentSize(
      NSSize(
        width: max(
          minimumWidth,
          min(contentWidth + horizontalInsets, CandidateWindowStyle.maximumWidth)
        ),
        height: fittingSize.height
      ))
  }

  func setRerankingActive(_ active: Bool) {
    if active {
      rerankingIndicator.isHidden = false
      rerankingIndicator.startAnimation(nil)
    } else {
      rerankingIndicator.stopAnimation(nil)
      rerankingIndicator.isHidden = true
    }
  }

  func hide() {
    setRerankingActive(false)
    candidates = []
    generatedCandidates = []
    displayedGeneratedCandidateCount = 0
    if panel.isVisible {
      panel.orderOut(nil)
    }
  }

  @objc private func selectCandidate(_ sender: NSButton) {
    if generatedCandidates.indices.contains(sender.tag) {
      generatedActionHandler?(sender.tag)
      return
    }
    guard candidates.indices.contains(sender.tag) else { return }
    actionHandler?(.select(candidates[sender.tag]))
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    panel.level = .popUpMenu
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.hasShadow = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    return panel
  }

  private func makeCandidateStack() -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = CandidateWindowStyle.candidateSpacing
    return stack
  }

  private func makeContentStack() -> NSStackView {
    let stack = NSStackView(views: [candidateStack, expandedHeader, expandedGrid])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.edgeInsets = CandidateWindowStyle.contentInsets
    let horizontalInsets =
      CandidateWindowStyle.contentInsets.left + CandidateWindowStyle.contentInsets.right
    candidateStack.widthAnchor.constraint(
      equalTo: stack.widthAnchor,
      constant: -horizontalInsets
    ).isActive = true
    return stack
  }

  private func makeBackgroundView() -> NSVisualEffectView {
    let background = CandidateBackgroundView()
    background.material = .popover
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = CandidateWindowStyle.cornerRadius
    background.layer?.borderWidth = CandidateWindowStyle.borderWidth
    background.layer?.masksToBounds = true
    background.addSubview(contentStack)
    background.addSubview(rerankingIndicator)
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    rerankingIndicator.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      contentStack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      contentStack.topAnchor.constraint(equalTo: background.topAnchor),
      contentStack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
      rerankingIndicator.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
      rerankingIndicator.trailingAnchor.constraint(
        equalTo: background.trailingAnchor,
        constant: -4
      ),
      rerankingIndicator.widthAnchor.constraint(equalToConstant: 12),
      rerankingIndicator.heightAnchor.constraint(equalToConstant: 12),
    ])
    return background
  }

  private func makeRerankingIndicator() -> NSProgressIndicator {
    let indicator = NSProgressIndicator()
    indicator.style = .spinning
    indicator.controlSize = .mini
    indicator.isIndeterminate = true
    indicator.isDisplayedWhenStopped = false
    indicator.isHidden = true
    indicator.toolTip = "AI 正在重排候选"
    indicator.setAccessibilityLabel("AI 正在重排候选")
    return indicator
  }

  private func rebuildCandidateRows(highlighted: Int?, anchor: NSRect) -> CGFloat {
    removeArrangedSubviews(from: candidateStack)

    let metrics = currentMetrics
    var buttons: [CandidateRowButton] = []
    var widths: [CGFloat] = []
    for (index, text) in visibleCandidateTexts.enumerated() {
      let button = CandidateRowButton(
        index: String(index + 1),
        text: text,
        metrics: metrics,
        target: self,
        action: #selector(selectCandidate(_:)),
        interactionHandler: interactionHandler
      )
      button.tag = index
      button.candidateHighlighted = highlighted == index
      buttons.append(button)
      widths.append(button.intrinsicContentSize.width)
    }

    let horizontalInsets =
      CandidateWindowStyle.contentInsets.left + CandidateWindowStyle.contentInsets.right
    let availableScreenWidth =
      (screen(containing: anchor)?.visibleFrame.width ?? NSScreen.main?.visibleFrame.width
        ?? CandidateWindowStyle.maximumWidth)
      - CandidateWindowStyle.screenInset * 2
    let horizontalContentWidth =
      widths.reduce(0, +)
      + CandidateWindowStyle.candidateSpacing * CGFloat(max(0, widths.count - 1))
    let horizontalLimit = min(
      CandidateWindowStyle.maximumWidth - horizontalInsets,
      max(0, availableScreenWidth - horizontalInsets)
    )
    resolvedCompactLayout =
      generatedCandidates.isEmpty && layoutSettings.layout == .horizontal
        && horizontalContentWidth <= horizontalLimit
      ? .horizontal : .vertical
    candidateStack.orientation = resolvedCompactLayout == .horizontal ? .horizontal : .vertical
    candidateStack.alignment = resolvedCompactLayout == .horizontal ? .centerY : .leading

    for button in buttons {
      candidateStack.addArrangedSubview(button)
      if resolvedCompactLayout == .vertical {
        button.widthAnchor.constraint(equalTo: candidateStack.widthAnchor).isActive = true
      }
    }
    if resolvedCompactLayout == .horizontal {
      return horizontalContentWidth
    }
    return widths.max() ?? metrics.fallbackColumnWidth
  }

  private func makeExpandedHeader() -> NSTextField {
    let metrics = currentMetrics
    let label = NSTextField(labelWithString: "")
    label.font = metrics.expandedHeaderFont
    label.textColor = .secondaryLabelColor
    label.maximumNumberOfLines = 1
    let heightConstraint = label.heightAnchor.constraint(
      greaterThanOrEqualToConstant: metrics.expandedHeaderHeight
    )
    heightConstraint.isActive = true
    expandedHeaderHeightConstraint = heightConstraint
    label.isHidden = true
    return label
  }

  private func makeExpandedGrid() -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.alignment = .top
    stack.spacing = CandidateWindowStyle.expandedColumnSpacing
    stack.isHidden = true
    return stack
  }

  private func rebuildExpandedGrid(
    highlighted: Int,
    pageSize: Int,
    layout: CandidateLayout
  ) -> CGFloat {
    removeArrangedSubviews(from: expandedGrid)
    numberedExpandedIndices = []
    let metrics = currentMetrics

    let expandedPageSize = pageSize * CandidateWindowStyle.expandedColumnCount
    let start =
      min(max(0, highlighted), candidates.count - 1) / expandedPageSize
      * expandedPageSize
    let end = min(candidates.count, start + expandedPageSize)
    let columnCount = layout == .horizontal ? pageSize : CandidateWindowStyle.expandedColumnCount
    let horizontalInsets =
      CandidateWindowStyle.contentInsets.left + CandidateWindowStyle.contentInsets.right
    let maximumColumnWidth =
      (CandidateWindowStyle.maximumWidth - horizontalInsets
        - CandidateWindowStyle.expandedColumnSpacing
        * CGFloat(max(0, columnCount - 1)))
      / CGFloat(columnCount)
    let columnWidth = min(measuredCandidateWidth(in: start..<end), maximumColumnWidth)
    guard start < end else { return 0 }

    var renderedColumnCount = 0
    for columnOffset in 0..<columnCount {
      let column = NSStackView()
      column.orientation = .vertical
      column.alignment = .leading
      column.spacing = CandidateWindowStyle.candidateSpacing
      column.widthAnchor.constraint(equalToConstant: columnWidth)
        .isActive = true
      let indices: [Int]
      switch layout {
      case .vertical:
        let columnStart = start + columnOffset * pageSize
        indices = Array(columnStart..<min(end, columnStart + pageSize))
      case .horizontal:
        indices = stride(
          from: start + columnOffset,
          to: end,
          by: pageSize
        ).map { $0 }
      }
      guard !indices.isEmpty else { continue }
      for index in indices {
        let isNumbered = index / pageSize == highlighted / pageSize
        if isNumbered {
          numberedExpandedIndices.append(index)
        }
        let number = isNumbered ? String(index % pageSize + 1) : ""
        let button = CandidateRowButton(
          index: number,
          text: candidates[index].text,
          metrics: metrics,
          target: self,
          action: #selector(selectCandidate(_:)),
          interactionHandler: interactionHandler
        )
        button.tag = index
        button.candidateHighlighted = highlighted == index
        column.addArrangedSubview(button)
        button.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
      }
      expandedGrid.addArrangedSubview(column)
      renderedColumnCount += 1
    }
    return columnWidth * CGFloat(renderedColumnCount)
      + CandidateWindowStyle.expandedColumnSpacing * CGFloat(max(0, renderedColumnCount - 1))
  }

  private func measuredCandidateWidth(in range: Range<Int>) -> CGFloat {
    let metrics = currentMetrics
    var measuredWidth: CGFloat = 0
    for index in range {
      let button = CandidateRowButton(
        index: "1",
        text: visibleCandidateTexts[index],
        metrics: metrics,
        target: nil,
        action: nil
      )
      measuredWidth = max(measuredWidth, button.intrinsicContentSize.width)
    }
    return measuredWidth > 0 ? measuredWidth : metrics.fallbackColumnWidth
  }

  private var currentMetrics: CandidateWindowMetrics {
    CandidateWindowStyle.metrics(fontSize: appliedFontSize)
  }

  private var visibleCandidateTexts: [String] {
    generatedCandidates.isEmpty ? candidates.map(\.text) : generatedCandidates.map(\.text)
  }

  private func removeArrangedSubviews(from stack: NSStackView) {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }

  private func positionPanel(at anchor: NSRect) {
    let visibleFrame =
      screen(containing: anchor)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    let gap = CandidateWindowStyle.panelGap
    var origin = NSPoint(x: anchor.minX, y: anchor.minY - panel.frame.height - gap)
    if origin.y < visibleFrame.minY {
      origin.y = anchor.maxY + gap
    }
    let inset = CandidateWindowStyle.screenInset
    origin.x = min(
      max(origin.x, visibleFrame.minX + inset),
      visibleFrame.maxX - panel.frame.width - inset
    )
    origin.y = min(
      max(origin.y, visibleFrame.minY + inset),
      visibleFrame.maxY - panel.frame.height - inset
    )
    panel.setFrameOrigin(origin)
  }

  private func positionPanel(beside anchor: NSRect) {
    let visibleFrame =
      screen(containing: anchor)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    let gap = CandidateWindowStyle.panelGap
    var origin = NSPoint(x: anchor.maxX + gap, y: anchor.maxY - panel.frame.height)
    if origin.x + panel.frame.width > visibleFrame.maxX - CandidateWindowStyle.screenInset {
      origin.x = anchor.minX - panel.frame.width - gap
    }
    let inset = CandidateWindowStyle.screenInset
    origin.x = min(
      max(origin.x, visibleFrame.minX + inset),
      visibleFrame.maxX - panel.frame.width - inset
    )
    origin.y = min(
      max(origin.y, visibleFrame.minY + inset),
      visibleFrame.maxY - panel.frame.height - inset
    )
    panel.setFrameOrigin(origin)
  }

  private func screen(containing rect: NSRect) -> NSScreen? {
    NSScreen.screens.first { $0.frame.intersects(rect) }
  }
}
