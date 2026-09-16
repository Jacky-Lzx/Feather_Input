import AppKit

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
        width: max(220, min(fittingSize.width, 520)),
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

  @objc private func showPreviousPage(_ sender: Any?) {
    actionHandler?(.pageUp)
  }

  @objc private func showNextPage(_ sender: Any?) {
    actionHandler?(.pageDown)
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
    stack.spacing = 2
    return stack
  }

  private func makeContentStack() -> NSStackView {
    let previous = pageButton(title: "◀", action: #selector(showPreviousPage(_:)))
    previous.toolTip = "上一页"
    let next = pageButton(title: "▶", action: #selector(showNextPage(_:)))
    next.toolTip = "下一页"

    let footer = NSStackView(views: [previous, next])
    footer.orientation = .horizontal
    footer.alignment = .centerY
    footer.spacing = 4

    let stack = NSStackView(views: [candidateStack, footer])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    return stack
  }

  private func makeBackgroundView() -> NSVisualEffectView {
    let background = NSVisualEffectView()
    background.material = .popover
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 9
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

  private func pageButton(title: String, action: Selector) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .roundRect
    button.controlSize = .small
    button.setButtonType(.momentaryPushIn)
    return button
  }

  private func rebuildCandidateRows(highlighted: Int?) {
    for view in candidateStack.arrangedSubviews {
      candidateStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    for (index, candidate) in candidates.enumerated() {
      let button = NSButton(
        title: "\(index + 1).  \(candidate.text)",
        target: self,
        action: #selector(selectCandidate(_:))
      )
      button.tag = index
      button.alignment = .left
      button.bezelStyle = .roundRect
      button.setButtonType(.momentaryPushIn)
      button.isBordered = highlighted == index
      button.font = .systemFont(ofSize: 16)
      button.contentTintColor = .labelColor
      candidateStack.addArrangedSubview(button)
    }
  }

  private func positionPanel(at anchor: NSRect) {
    let visibleFrame =
      screen(containing: anchor)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    let gap: CGFloat = 6
    var origin = NSPoint(x: anchor.minX, y: anchor.minY - panel.frame.height - gap)
    if origin.y < visibleFrame.minY {
      origin.y = anchor.maxY + gap
    }
    origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - panel.frame.width)
    origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - panel.frame.height)
    panel.setFrameOrigin(origin)
  }

  private func screen(containing rect: NSRect) -> NSScreen? {
    NSScreen.screens.first { $0.frame.intersects(rect) }
  }
}
