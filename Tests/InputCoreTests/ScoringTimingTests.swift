import XCTest
@testable import InputCore

final class ScoringTimingTests: XCTestCase {
    func testOverrideDefaultsAndBounds() {
        let name = "feather-timing-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(ScoringTiming(defaults: defaults).debounceMS, 120)
        XCTAssertEqual(ScoringTiming(defaults: defaults).responseLimitMS, 700)
        defaults.set(0, forKey: "debugScoringDebounceMS")
        defaults.set(1500, forKey: "debugScoringResponseLimitMS")
        XCTAssertEqual(ScoringTiming(defaults: defaults).debounceMS, 120)
        defaults.set(true, forKey: "debugScoringTimingEnabled")
        XCTAssertEqual(ScoringTiming(defaults: defaults).debounceMS, 0)
        XCTAssertEqual(ScoringTiming(defaults: defaults).responseLimitMS, 1500)
        defaults.set(-1, forKey: "debugScoringResponseLimitMS")
        defaults.set(99999, forKey: "debugScoringDebounceMS")
        XCTAssertEqual(ScoringTiming(defaults: defaults).responseLimitMS, 50)
        XCTAssertEqual(ScoringTiming(defaults: defaults).debounceMS, 2000)
    }
}
