import Foundation

final class CandidatePageSettings {
  static let shared = CandidatePageSettings()

  static let defaultCount = 7
  static let minimumCount = 1
  static let maximumCount = 9

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var count: Int {
    let stored = defaults.object(forKey: "candidateCount") as? Int ?? Self.defaultCount
    return min(max(stored, Self.minimumCount), Self.maximumCount)
  }

  func updateCount(_ count: Int) {
    defaults.set(
      min(max(count, Self.minimumCount), Self.maximumCount),
      forKey: "candidateCount"
    )
  }
}
