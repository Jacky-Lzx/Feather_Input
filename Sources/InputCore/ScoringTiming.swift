import Foundation

public struct ScoringTiming: Equatable {
    public let debounceMS: Int
    public let responseLimitMS: Int
    public init(defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: "debugScoringTimingEnabled") else {
            debounceMS = 120; responseLimitMS = 700
            return
        }
        debounceMS = min(2000, max(0, defaults.object(forKey: "debugScoringDebounceMS") as? Int ?? 120))
        responseLimitMS = min(2000, max(50, defaults.object(forKey: "debugScoringResponseLimitMS") as? Int ?? 700))
    }
}
