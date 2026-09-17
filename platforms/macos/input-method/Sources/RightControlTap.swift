import Foundation

struct RightControlTap {
  static let rightControl: UInt = 0x2000
  private static let disallowed: UInt = 0x1 | (1 << 17) | (1 << 19) | (1 << 20) | (1 << 23)
  private static let debounceInterval = 0.040

  private var leftHeld = false
  private var held = false
  private var eligible = false
  private var lastRelease: Double?

  mutating func cancel() {
    eligible = false
  }

  mutating func reset() {
    leftHeld = false
    held = false
    eligible = false
  }

  mutating func flagsChanged(keyCode: UInt16, flags: UInt, timestamp: Double?) -> Bool {
    let controlDown = flags & ((1 << 18) | Self.rightControl | 0x1) != 0
    let sideBits = flags & (Self.rightControl | 0x1)
    if keyCode == 59 {
      leftHeld = sideBits != 0 ? flags & 0x1 != 0 : controlDown && !leftHeld
    } else if !controlDown {
      leftHeld = false
    }

    let rightDown =
      sideBits != 0 ? flags & Self.rightControl != 0 : controlDown && (!leftHeld || !held)
    let clean = !leftHeld && flags & Self.disallowed == 0
    guard keyCode == 62 else {
      cancel()
      if !controlDown { held = false }
      return false
    }
    if rightDown {
      if !held {
        let repeated =
          timestamp.flatMap { timestamp in
            lastRelease.map { timestamp - $0 < Self.debounceInterval }
          } ?? false
        eligible = clean && !repeated
      } else if !clean {
        cancel()
      }
      held = true
      return false
    }

    let toggle = held && eligible && clean
    if held, let timestamp {
      lastRelease = max(lastRelease ?? timestamp, timestamp)
    }
    held = false
    eligible = false
    return toggle
  }
}
