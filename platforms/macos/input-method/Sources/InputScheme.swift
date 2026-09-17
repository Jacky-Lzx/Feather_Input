import Foundation

enum InputScheme: String, CaseIterable {
  case fullPinyin = "luna_pinyin_simp"
  case flypy = "double_pinyin_flypy"

  var title: String {
    switch self {
    case .fullPinyin: "全拼"
    case .flypy: "小鹤双拼"
    }
  }
}

final class InputSchemeMemory {
  static let shared = InputSchemeMemory()

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> InputScheme {
    InputScheme(rawValue: defaults.string(forKey: "inputScheme") ?? "") ?? .fullPinyin
  }

  func update(_ scheme: InputScheme) {
    defaults.set(scheme.rawValue, forKey: "inputScheme")
  }
}
