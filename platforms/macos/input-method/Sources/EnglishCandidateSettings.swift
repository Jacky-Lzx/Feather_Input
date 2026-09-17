import Foundation

final class EnglishCandidateSettings {
  static let shared = EnglishCandidateSettings()

  static let defaultMinimum = 5
  static let minimumValue = 1
  static let maximumValue = 12

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var minimumInputLength: Int {
    let stored =
      defaults.object(forKey: "englishCandidateMinimum") as? Int ?? Self.defaultMinimum
    return min(max(stored, Self.minimumValue), Self.maximumValue)
  }

  func updateMinimumInputLength(_ value: Int) {
    defaults.set(
      min(max(value, Self.minimumValue), Self.maximumValue),
      forKey: "englishCandidateMinimum"
    )
  }
}
