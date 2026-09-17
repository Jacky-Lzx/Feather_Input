import AppKit

@MainActor
final class SmokeCandidatePresenter: CandidatePresenting {
  var actionHandler: ((CandidateWindowAction) -> Void)?
  private(set) var candidates: [FeatherCandidateValue] = []
  private(set) var highlighted: Int?
  private(set) var anchor = NSRect.zero
  private(set) var updateCount = 0
  private(set) var hideCount = 0
  private(set) var expanded = false
  private(set) var expandedHasMore = false

  func update(
    candidates: [FeatherCandidateValue],
    highlighted: Int?,
    anchor: NSRect
  ) {
    expanded = false
    self.candidates = candidates
    self.highlighted = highlighted
    self.anchor = anchor
    updateCount += 1
  }

  func updateExpanded(
    candidates: [FeatherCandidateValue],
    highlighted: Int,
    rows: Int,
    hasMore: Bool,
    anchor: NSRect
  ) {
    expanded = true
    expandedHasMore = hasMore
    self.candidates = candidates
    self.highlighted = highlighted
    self.anchor = anchor
    updateCount += 1
  }

  func hide() {
    expanded = false
    candidates = []
    hideCount += 1
  }

  func select(text: String) {
    guard let candidate = candidates.first(where: { $0.text == text }) else { return }
    actionHandler?(.select(candidate))
  }

  func select(at index: Int) {
    guard candidates.indices.contains(index) else { return }
    actionHandler?(.select(candidates[index]))
  }

  func pageDown() {
    actionHandler?(.pageDown)
  }
}
