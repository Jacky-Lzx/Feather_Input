import AppKit

@MainActor
final class SmokeGeneratedCandidatePresenter: GeneratedCandidatePresenting {
  var generatedActionHandler: ((Int) -> Void)?
  private(set) var candidates: [FeatherGeneratedCandidateValue] = []
  private(set) var anchor = NSRect.zero
  private(set) var hideCount = 0
  private(set) var repositionCount = 0
  var isVisible: Bool { !candidates.isEmpty }

  private(set) var title: String?

  func update(
    candidates: [FeatherGeneratedCandidateValue],
    beside anchor: NSRect,
    title: String?
  ) {
    self.candidates = candidates
    self.anchor = anchor
    self.title = title
  }

  func reposition(beside anchor: NSRect) {
    guard isVisible else { return }
    self.anchor = anchor
    repositionCount += 1
  }

  func hide() {
    candidates = []
    title = nil
    hideCount += 1
  }

  func select(at index: Int) {
    guard candidates.indices.contains(index) else { return }
    generatedActionHandler?(index)
  }
}
