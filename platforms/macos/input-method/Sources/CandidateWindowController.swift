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
    index: Int,
    text: String,
    target: AnyObject?,
    action: Selector?
  ) {
    self.init(frame: .zero)
    self.target = target
    self.action = action
    indexLabel.stringValue = String(index)
    candidateLabel.stringValue = text
    setAccessibilityLabel("候选 \(index)：\(text)")
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
  func hide()
}

@MainActor
final class CandidateWindowController: NSObject, CandidatePresenting {
  var actionHandler: ((CandidateWindowAction) -> Void)?

  private var candidates: [FeatherCandidateValue] = []
  private lazy var panel = makePanel()
  private lazy var candidateStack = makeCandidateStack()
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
    rebuildCandidateRows(highlighted: highlighted)
    panel.contentView = backgroundView
    backgroundView.layoutSubtreeIfNeeded()
    let fittingSize = backgroundView.fittingSize
    panel.setContentSize(
      NSSize(
        width: max(
          CandidateWindowStyle.minimumWidth,
          min(fittingSize.width, CandidateWindowStyle.maximumWidth)
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
    let stack = NSStackView(views: [candidateStack])
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

  private func rebuildCandidateRows(highlighted: Int?) {
    for view in candidateStack.arrangedSubviews {
      candidateStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    for (index, candidate) in candidates.enumerated() {
      let button = CandidateRowButton(
        index: index + 1,
        text: candidate.text,
        target: self,
        action: #selector(selectCandidate(_:))
      )
      button.tag = index
      button.candidateHighlighted = highlighted == index
      candidateStack.addArrangedSubview(button)
      button.widthAnchor.constraint(equalTo: candidateStack.widthAnchor).isActive = true
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
