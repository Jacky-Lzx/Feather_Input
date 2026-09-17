import AppKit

@MainActor
final class SmokeModePresenter: ModeIndicatorPresenting {
  private(set) var isVisible = false
  private(set) var directMode: Bool?
  private(set) var anchor = NSRect.zero
  private(set) var clientLevel = 0
  private(set) var showCount = 0
  private(set) var waitsUntilInput = false
  private(set) var duration: TimeInterval = 0

  func show(
    directMode: Bool,
    anchor: NSRect,
    clientLevel: Int,
    waitsUntilInput: Bool,
    duration: TimeInterval
  ) {
    isVisible = true
    self.directMode = directMode
    self.anchor = anchor
    self.clientLevel = clientLevel
    self.waitsUntilInput = waitsUntilInput
    self.duration = duration
    showCount += 1
  }

  func hide() {
    isVisible = false
  }
}
