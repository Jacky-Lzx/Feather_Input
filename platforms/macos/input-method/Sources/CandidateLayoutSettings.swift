import Foundation

enum CandidateLayout: String, CaseIterable {
  case vertical
  case horizontal

  var title: String {
    switch self {
    case .vertical: "竖排"
    case .horizontal: "横排"
    }
  }
}

final class CandidateLayoutSettings {
  static let shared = CandidateLayoutSettings()

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var layout: CandidateLayout {
    CandidateLayout(rawValue: defaults.string(forKey: "candidateLayout") ?? "") ?? .vertical
  }

  func update(_ layout: CandidateLayout) {
    defaults.set(layout.rawValue, forKey: "candidateLayout")
  }
}
