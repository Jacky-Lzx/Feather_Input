import Foundation

public enum ScoringCandidateLimit {
    public static func count(pageCount: Int, defaults: UserDefaults = .standard) -> Int {
        guard defaults.bool(forKey: "debugScoringCandidateLimitEnabled") else { return min(9, max(1, pageCount)) }
        return min(64, max(1, defaults.object(forKey: "debugScoringCandidateLimit") as? Int ?? 20))
    }
}
