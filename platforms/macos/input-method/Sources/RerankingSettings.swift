import Foundation

extension Notification.Name {
  static let rerankingSettingsDidChange = Notification.Name(
    "FeatherRerankingSettingsDidChange"
  )
}

final class RerankingSettings {
  static let shared = RerankingSettings()

  static let defaultEnabled = false
  static let defaultWeight = 0.35
  static let defaultDebounceMilliseconds: UInt64 = 120
  static let defaultAdoptionDeadlineMilliseconds: UInt64 = 700

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var isEnabled: Bool {
    defaults.object(forKey: "aiRimeRerankingEnabled") as? Bool ?? Self.defaultEnabled
  }

  var weight: Double {
    let stored = defaults.object(forKey: "aiRimeRerankingWeight") as? Double
    return min(1, max(0, stored ?? Self.defaultWeight))
  }

  var debounceMilliseconds: UInt64 {
    boundedInteger(
      key: "aiRimeRerankingDebounceMilliseconds",
      fallback: Self.defaultDebounceMilliseconds,
      range: 0...2_000
    )
  }

  var adoptionDeadlineMilliseconds: UInt64 {
    boundedInteger(
      key: "aiRimeRerankingAdoptionDeadlineMilliseconds",
      fallback: Self.defaultAdoptionDeadlineMilliseconds,
      range: 50...2_000
    )
  }

  func updateEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: "aiRimeRerankingEnabled")
    notify()
  }

  func updateWeight(_ weight: Double) {
    defaults.set(min(1, max(0, weight)), forKey: "aiRimeRerankingWeight")
    notify()
  }

  func updateDebounceMilliseconds(_ milliseconds: UInt64) {
    defaults.set(min(2_000, milliseconds), forKey: "aiRimeRerankingDebounceMilliseconds")
    notify()
  }

  func updateAdoptionDeadlineMilliseconds(_ milliseconds: UInt64) {
    defaults.set(
      min(2_000, max(50, milliseconds)),
      forKey: "aiRimeRerankingAdoptionDeadlineMilliseconds"
    )
    notify()
  }

  private func boundedInteger(
    key: String,
    fallback: UInt64,
    range: ClosedRange<UInt64>
  ) -> UInt64 {
    guard let number = defaults.object(forKey: key) as? NSNumber else { return fallback }
    let bounded = min(Int64(range.upperBound), max(Int64(range.lowerBound), number.int64Value))
    return UInt64(bounded)
  }

  private func notify() {
    NotificationCenter.default.post(name: .rerankingSettingsDidChange, object: self)
  }
}
