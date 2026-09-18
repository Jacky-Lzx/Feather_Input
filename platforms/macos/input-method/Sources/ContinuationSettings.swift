import Foundation

extension Notification.Name {
  static let continuationSettingsDidChange = Notification.Name(
    "FeatherContinuationSettingsDidChange"
  )
}

final class ContinuationSettings {
  static let shared = ContinuationSettings()

  static let defaultEnabled = false

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var isEnabled: Bool {
    defaults.object(forKey: "aiPostCommitContinuationEnabled") as? Bool
      ?? Self.defaultEnabled
  }

  func updateEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: "aiPostCommitContinuationEnabled")
    NotificationCenter.default.post(name: .continuationSettingsDidChange, object: self)
  }
}
