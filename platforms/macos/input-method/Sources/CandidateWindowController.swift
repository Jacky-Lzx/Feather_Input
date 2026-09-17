import AppKit

@MainActor
private final class CandidateRowButton: NSButton {
  private let indexLabel = NSTextField(labelWithString: "")
  private let candidateLabel = NSTextField(labelWithString: "")
  private var trackingArea: NSTrackingArea?
  private var hovering = false {
    didSet { needsDisplay = true }
  }

  var candidateHighlighted = false {
    didSet { needsDisplay = true }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureView()
  }

  convenience init(
    index: String,
    text: String,
    target: AnyObject?,
    action: Selector?
  ) {
    self.init(frame: .zero)
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
        + CandidateWindowStyle.indexWidth
        + CandidateWindowStyle.candidateLabelSpacing
        + candidateLabel.intrinsicContentSize.width,
      height: CandidateWindowStyle.candidateHeight
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
    indexLabel.font = CandidateWindowStyle.indexFont
    indexLabel.lineBreakMode = .byClipping
    indexLabel.maximumNumberOfLines = 1
    candidateLabel.font = CandidateWindowStyle.candidateFont
    candidateLabel.lineBreakMode = .byTruncatingTail
    candidateLabel.maximumNumberOfLines = 1
    candidateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    addSubview(indexLabel)
    addSubview(candidateLabel)
    indexLabel.translatesAutoresizingMaskIntoConstraints = false
    candidateLabel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: CandidateWindowStyle.candidateHeight),
      indexLabel.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: CandidateWindowStyle.candidateHorizontalPadding
      ),
      indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      indexLabel.widthAnchor.constraint(equalToConstant: CandidateWindowStyle.indexWidth),
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

  func update(
    candidates: [FeatherCandidateValue],
    highlighted: Int?,
    anchor: NSRect
  )
  func updateExpanded(
    candidates: [FeatherCandidateValue],
    highlighted: Int,
    rows: Int,
    hasMore: Bool,
    anchor: NSRect
  )
  func hide()
}

@MainActor
final class CandidateWindowController: NSObject, CandidatePresenting {
  var actionHandler: ((CandidateWindowAction) -> Void)?

  private var candidates: [FeatherCandidateValue] = []
  private lazy var panel = makePanel()
  private lazy var candidateStack = makeCandidateStack()
  private lazy var expandedHeader = makeExpandedHeader()
  private lazy var expandedGrid = makeExpandedGrid()
  private lazy var contentStack = makeContentStack()
  private lazy var backgroundView = makeBackgroundView()

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
    candidateStack.isHidden = false
    expandedHeader.isHidden = true
    expandedGrid.isHidden = true
    removeArrangedSubviews(from: expandedGrid)
    let columnWidth = rebuildCandidateRows(highlighted: highlighted)
    resizeAndShow(at: anchor, contentWidth: columnWidth)
  }

  func updateExpanded(
    candidates: [FeatherCandidateValue],
    highlighted: Int,
    rows: Int,
    hasMore: Bool,
    anchor: NSRect
  ) {
    guard !candidates.isEmpty, rows > 0 else {
      hide()
      return
    }

    self.candidates = candidates
    candidateStack.isHidden = true
    expandedHeader.isHidden = false
    expandedGrid.isHidden = false
    removeArrangedSubviews(from: candidateStack)
    expandedHeader.stringValue = "全部候选 · \(candidates.count)\(hasMore ? "+" : "")"
    let gridWidth = rebuildExpandedGrid(highlighted: highlighted, rows: rows)
    let contentWidth = max(gridWidth, expandedHeader.intrinsicContentSize.width)
    resizeAndShow(at: anchor, contentWidth: contentWidth)
  }

  private func resizeAndShow(at anchor: NSRect, contentWidth: CGFloat) {
    panel.contentView = backgroundView
    backgroundView.layoutSubtreeIfNeeded()
    let fittingSize = backgroundView.fittingSize
    let horizontalInsets =
      CandidateWindowStyle.contentInsets.left + CandidateWindowStyle.contentInsets.right
    panel.setContentSize(
      NSSize(
        width: max(
          CandidateWindowStyle.minimumWidth,
          min(contentWidth + horizontalInsets, CandidateWindowStyle.maximumWidth)
        ),
        height: fittingSize.height
      ))
    positionPanel(at: anchor)
    panel.orderFrontRegardless()
  }

  func hide() {
    candidates = []
    if panel.isVisible {
      panel.orderOut(nil)
    }
  }

  @objc private func selectCandidate(_ sender: NSButton) {
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
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      contentStack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      contentStack.topAnchor.constraint(equalTo: background.topAnchor),
      contentStack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
    ])
    return background
  }

  private func rebuildCandidateRows(highlighted: Int?) -> CGFloat {
    removeArrangedSubviews(from: candidateStack)

    var measuredWidth: CGFloat = 0
    for (index, candidate) in candidates.enumerated() {
      let button = CandidateRowButton(
        index: String(index + 1),
        text: candidate.text,
        target: self,
        action: #selector(selectCandidate(_:))
      )
      button.tag = index
      button.candidateHighlighted = highlighted == index
      measuredWidth = max(measuredWidth, button.intrinsicContentSize.width)
      candidateStack.addArrangedSubview(button)
      button.widthAnchor.constraint(equalTo: candidateStack.widthAnchor).isActive = true
    }
    return measuredWidth > 0 ? measuredWidth : CandidateWindowStyle.fallbackColumnWidth
  }

  private func makeExpandedHeader() -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = CandidateWindowStyle.expandedHeaderFont
    label.textColor = .secondaryLabelColor
    label.maximumNumberOfLines = 1
    label.heightAnchor.constraint(equalToConstant: CandidateWindowStyle.expandedHeaderHeight)
      .isActive = true
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

  private func rebuildExpandedGrid(highlighted: Int, rows: Int) -> CGFloat {
    removeArrangedSubviews(from: expandedGrid)

    let pageSize = rows * CandidateWindowStyle.expandedColumnCount
    let start = min(max(0, highlighted), candidates.count - 1) / pageSize * pageSize
    let end = min(candidates.count, start + pageSize)
    let activeColumn = highlighted / rows
    let horizontalInsets =
      CandidateWindowStyle.contentInsets.left + CandidateWindowStyle.contentInsets.right
    let maximumColumnWidth =
      (CandidateWindowStyle.maximumWidth - horizontalInsets
        - CandidateWindowStyle.expandedColumnSpacing
        * CGFloat(CandidateWindowStyle.expandedColumnCount - 1))
      / CGFloat(CandidateWindowStyle.expandedColumnCount)
    let columnWidth = min(measuredCandidateWidth(in: start..<end), maximumColumnWidth)
    guard start < end else { return 0 }

    var columnCount = 0
    for columnStart in stride(from: start, to: end, by: rows) {
      let column = NSStackView()
      column.orientation = .vertical
      column.alignment = .leading
      column.spacing = CandidateWindowStyle.candidateSpacing
      column.widthAnchor.constraint(equalToConstant: columnWidth)
        .isActive = true
      for index in columnStart..<min(end, columnStart + rows) {
        let number = index / rows == activeColumn ? String(index % rows + 1) : ""
        let button = CandidateRowButton(
          index: number,
          text: candidates[index].text,
          target: self,
          action: #selector(selectCandidate(_:))
        )
        button.tag = index
        button.candidateHighlighted = highlighted == index
        column.addArrangedSubview(button)
        button.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
      }
      expandedGrid.addArrangedSubview(column)
      columnCount += 1
    }
    return columnWidth * CGFloat(columnCount)
      + CandidateWindowStyle.expandedColumnSpacing * CGFloat(max(0, columnCount - 1))
  }

  private func measuredCandidateWidth(in range: Range<Int>) -> CGFloat {
    var measuredWidth: CGFloat = 0
    for index in range {
      let button = CandidateRowButton(
        index: "1",
        text: candidates[index].text,
        target: nil,
        action: nil
      )
      measuredWidth = max(measuredWidth, button.intrinsicContentSize.width)
    }
    return measuredWidth > 0 ? measuredWidth : CandidateWindowStyle.fallbackColumnWidth
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

  private func screen(containing rect: NSRect) -> NSScreen? {
    NSScreen.screens.first { $0.frame.intersects(rect) }
  }
}
