import AppKit

@MainActor
final class SmokePersistentModePresenter: PersistentModeIndicatorPresenting {
  private(set) var isVisible = false
  private(set) var directMode: Bool?
  private(set) var showCount = 0

  func show(directMode: Bool) {
    isVisible = true
    self.directMode = directMode
    showCount += 1
  }

  func hide() {
    isVisible = false
  }
}
