import Foundation

/// Caps Lock reports latch-state changes instead of a normal key-down/key-up pair.
struct CapsLockSwitch {
  private static let capsLock: UInt = 1 << 16
  private static let disallowed: UInt =
    (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23)

  private var locked = false

  mutating func reset(isLocked: Bool) {
    locked = isLocked
  }

  mutating func flagsChanged(keyCode: UInt16, flags: UInt) -> Bool {
    let next = flags & Self.capsLock != 0
    let changed = next != locked
    locked = next
    return (keyCode == 57 || keyCode == 0) && changed && flags & Self.disallowed == 0
  }
}
