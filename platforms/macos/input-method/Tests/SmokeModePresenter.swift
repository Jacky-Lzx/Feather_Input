import AppKit

@MainActor
final class SmokeModePresenter: ModeIndicatorPresenting {
  private(set) var isVisible = false
  private(set) var directMode: Bool?
  private(set) var anchor = NSRect.zero
  private(set) var clientLevel = 0
  private(set) var showCount = 0

  func show(directMode: Bool, anchor: NSRect, clientLevel: Int) {
    isVisible = true
    self.directMode = directMode
    self.anchor = anchor
    self.clientLevel = clientLevel
    showCount += 1
  }

  func hide() {
    isVisible = false
  }
}
