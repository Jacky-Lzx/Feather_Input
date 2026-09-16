import Foundation

public enum InputModeMemoryPolicy: String, CaseIterable, Sendable {
    case perApplication
    case global
    case resetToChinese
    case resetToEnglish
}

/// Keeps Chinese/English mode semantics independent from IMK controller
/// lifetime. InputMethodKit commonly creates one controller per client, but
/// that behavior alone is not a reliable mode-memory policy.
public final class InputModeMemory {
    public static let shared = InputModeMemory()

    private let defaults: UserDefaults
    private var currentASCII = false
    private var lastApplication = ""

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var policy: InputModeMemoryPolicy {
        InputModeMemoryPolicy(rawValue: defaults.string(forKey: "inputModeMemoryPolicy") ?? "") ?? .global
    }

    public func activate(application: String) -> Bool {
        let identifier = application.isEmpty ? "unknown" : application
        switch policy {
        case .perApplication:
            let stored = defaults.dictionary(forKey: "inputModeByApplication")?[identifier] as? Bool
            currentASCII = stored ?? false
        case .global:
            currentASCII = defaults.object(forKey: "inputModeGlobalASCII") as? Bool ?? currentASCII
        case .resetToChinese, .resetToEnglish:
            if identifier != lastApplication {
                currentASCII = policy == .resetToEnglish
            }
        }
        lastApplication = identifier
        return currentASCII
    }

    public func update(ascii: Bool, application: String) {
        let identifier = application.isEmpty ? "unknown" : application
        currentASCII = ascii
        lastApplication = identifier
        switch policy {
        case .perApplication:
            var stored = defaults.dictionary(forKey: "inputModeByApplication") ?? [:]
            stored[identifier] = ascii
            defaults.set(stored, forKey: "inputModeByApplication")
        case .global:
            defaults.set(ascii, forKey: "inputModeGlobalASCII")
        case .resetToChinese, .resetToEnglish:
            break
        }
    }
}
