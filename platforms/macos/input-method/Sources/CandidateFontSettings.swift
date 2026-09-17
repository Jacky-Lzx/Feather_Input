import Foundation

final class CandidateFontSettings {
  static let shared = CandidateFontSettings()

  static let defaultSize: CGFloat = 17
  static let minimumSize: CGFloat = 14
  static let maximumSize: CGFloat = 24

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var size: CGFloat {
    let stored = defaults.object(forKey: "candidateFontSize") as? Double
    return Self.clamp(CGFloat(stored ?? Double(Self.defaultSize)))
  }

  func updateSize(_ size: CGFloat) {
    defaults.set(Double(Self.clamp(size).rounded()), forKey: "candidateFontSize")
  }

  private static func clamp(_ size: CGFloat) -> CGFloat {
    min(max(size, minimumSize), maximumSize)
  }
}
