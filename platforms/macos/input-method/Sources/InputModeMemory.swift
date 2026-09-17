import Foundation

enum InputModeMemoryPolicy: String {
  case perApplication
  case global
  case resetToChinese
  case resetToEnglish
}

final class InputModeMemory {
  static let shared = InputModeMemory()

  private let defaults: UserDefaults
  private var currentDirectMode = false
  private var lastApplication = ""

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var policy: InputModeMemoryPolicy {
    InputModeMemoryPolicy(rawValue: defaults.string(forKey: "inputModeMemoryPolicy") ?? "")
      ?? .global
  }

  func activate(application: String) -> Bool {
    let identifier = application.isEmpty ? "unknown" : application
    switch policy {
    case .perApplication:
      let stored = defaults.dictionary(forKey: "inputModeByApplication")?[identifier] as? Bool
      currentDirectMode = stored ?? false
    case .global:
      currentDirectMode =
        defaults.object(forKey: "inputModeGlobalDirect") as? Bool ?? currentDirectMode
    case .resetToChinese, .resetToEnglish:
      if identifier != lastApplication {
        currentDirectMode = policy == .resetToEnglish
      }
    }
    lastApplication = identifier
    return currentDirectMode
  }

  func update(directMode: Bool, application: String) {
    let identifier = application.isEmpty ? "unknown" : application
    currentDirectMode = directMode
    lastApplication = identifier
    switch policy {
    case .perApplication:
      var stored = defaults.dictionary(forKey: "inputModeByApplication") ?? [:]
      stored[identifier] = directMode
      defaults.set(stored, forKey: "inputModeByApplication")
    case .global:
      defaults.set(directMode, forKey: "inputModeGlobalDirect")
    case .resetToChinese, .resetToEnglish:
      break
    }
  }
}
