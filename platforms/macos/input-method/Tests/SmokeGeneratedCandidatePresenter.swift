import AppKit

@MainActor
final class SmokeGeneratedCandidatePresenter: GeneratedCandidatePresenting {
  var generatedActionHandler: ((Int) -> Void)?
  private(set) var candidates: [FeatherGeneratedCandidateValue] = []
  private(set) var anchor = NSRect.zero
  private(set) var hideCount = 0
  var isVisible: Bool { !candidates.isEmpty }

  func update(candidates: [FeatherGeneratedCandidateValue], beside anchor: NSRect) {
    self.candidates = candidates
    self.anchor = anchor
  }

  func hide() {
    candidates = []
    hideCount += 1
  }

  func select(at index: Int) {
    guard candidates.indices.contains(index) else { return }
    generatedActionHandler?(index)
  }
}
