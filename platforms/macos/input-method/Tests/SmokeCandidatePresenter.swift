import AppKit

@MainActor
final class SmokeCandidatePresenter: CandidatePresenting {
  var actionHandler: ((CandidateWindowAction) -> Void)?
  private(set) var candidates: [FeatherCandidateValue] = []
  private(set) var highlighted: Int?
  private(set) var anchor = NSRect.zero
  private(set) var updateCount = 0
  private(set) var hideCount = 0

  func update(
    candidates: [FeatherCandidateValue],
    highlighted: Int?,
    anchor: NSRect
  ) {
    self.candidates = candidates
    self.highlighted = highlighted
    self.anchor = anchor
    updateCount += 1
  }

  func hide() {
    candidates = []
    hideCount += 1
  }

  func select(text: String) {
    guard let candidate = candidates.first(where: { $0.text == text }) else { return }
    actionHandler?(.select(candidate))
  }

  func pageDown() {
    actionHandler?(.pageDown)
  }
}
