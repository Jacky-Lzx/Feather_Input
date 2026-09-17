import Foundation

extension Notification.Name {
  static let generationSettingsDidChange = Notification.Name(
    "FeatherGenerationSettingsDidChange"
  )
}

final class GenerationSettings {
  static let shared = GenerationSettings()

  static let defaultEnabled = true

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var isEnabled: Bool {
    defaults.object(forKey: "aiPinyinGenerationEnabled") as? Bool ?? Self.defaultEnabled
  }

  func updateEnabled(_ isEnabled: Bool) {
    defaults.set(isEnabled, forKey: "aiPinyinGenerationEnabled")
    NotificationCenter.default.post(name: .generationSettingsDidChange, object: self)
  }
}
