import Foundation

@MainActor
final class SmokeContinuationShortcut: ContinuationShortcutRegistering {
  private var action: (() -> Void)?
  private(set) var isActive = false

  @discardableResult
  func activate(action: @escaping () -> Void) -> Bool {
    self.action = action
    isActive = true
    return true
  }

  func deactivate() {
    action = nil
    isActive = false
  }

  func trigger() {
    action?()
  }
}
