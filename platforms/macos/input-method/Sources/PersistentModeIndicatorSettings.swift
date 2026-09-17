import Foundation

extension Notification.Name {
  static let persistentModeIndicatorSettingsDidChange = Notification.Name(
    "FeatherPersistentModeIndicatorSettingsDidChange"
  )
}

final class PersistentModeIndicatorSettings {
  static let shared = PersistentModeIndicatorSettings()

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var isEnabled: Bool {
    defaults.object(forKey: "showPersistentMode") as? Bool ?? true
  }

  func updateEnabled(_ isEnabled: Bool) {
    defaults.set(isEnabled, forKey: "showPersistentMode")
    NotificationCenter.default.post(
      name: .persistentModeIndicatorSettingsDidChange,
      object: self
    )
  }
}
