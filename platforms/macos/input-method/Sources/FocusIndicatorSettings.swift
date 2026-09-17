import Foundation

final class FocusIndicatorSettings {
  static let shared = FocusIndicatorSettings()

  static let defaultDuration: TimeInterval = 3.0
  static let minimumDuration: TimeInterval = 0.1
  static let maximumDuration: TimeInterval = 5.0

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var waitsUntilInput: Bool {
    defaults.object(forKey: "focusModeUntilInput") as? Bool ?? false
  }

  var duration: TimeInterval {
    let stored =
      defaults.object(forKey: "focusModeDuration") as? Double
      ?? Self.defaultDuration
    guard stored.isFinite else { return Self.defaultDuration }
    return min(max(stored, Self.minimumDuration), Self.maximumDuration)
  }

  func updateWaitsUntilInput(_ waitsUntilInput: Bool) {
    defaults.set(waitsUntilInput, forKey: "focusModeUntilInput")
  }

  func updateDuration(_ duration: TimeInterval) {
    let value = duration.isFinite ? duration : Self.defaultDuration
    defaults.set(
      min(max(value, Self.minimumDuration), Self.maximumDuration),
      forKey: "focusModeDuration"
    )
  }
}
