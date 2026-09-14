import XCTest
@testable import InputCore
final class ScoringCandidateLimitTests: XCTestCase {
    func testIndependentCandidateLimit() {
        let name = "feather-candidate-limit-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(ScoringCandidateLimit.count(pageCount: 7, defaults: defaults), 7)
        defaults.set(true, forKey: "debugScoringCandidateLimitEnabled")
        XCTAssertEqual(ScoringCandidateLimit.count(pageCount: 7, defaults: defaults), 20)
        defaults.set(1, forKey: "debugScoringCandidateLimit")
        XCTAssertEqual(ScoringCandidateLimit.count(pageCount: 7, defaults: defaults), 1)
        defaults.set(999, forKey: "debugScoringCandidateLimit")
        XCTAssertEqual(ScoringCandidateLimit.count(pageCount: 7, defaults: defaults), 64)
        defaults.set(false, forKey: "debugScoringCandidateLimitEnabled")
        XCTAssertEqual(ScoringCandidateLimit.count(pageCount: 7, defaults: defaults), 7)
    }
}
