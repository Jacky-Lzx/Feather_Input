import XCTest
@testable import InputCore
final class RightControlTapTests: XCTestCase {
    let right = RightControlTap.rightControl | (1 << 18)
    func testIMKNormalizedFlagsWithoutDeviceBits() {
        var tap = RightControlTap()
        XCTAssertFalse(tap.flagsChanged(keyCode: 62, flags: 1 << 18))
        XCTAssertTrue(tap.flagsChanged(keyCode: 62, flags: 0))
    }
    func testNormalizedLeftControlDoesNotToggleOrAllowChord() {
        var tap = RightControlTap()
        XCTAssertFalse(tap.flagsChanged(keyCode: 59, flags: 1 << 18))
        XCTAssertFalse(tap.flagsChanged(keyCode: 62, flags: 1 << 18))
        XCTAssertFalse(tap.flagsChanged(keyCode: 59, flags: 1 << 18))
        XCTAssertFalse(tap.flagsChanged(keyCode: 62, flags: 0))
        _ = tap.flagsChanged(keyCode: 62, flags: 1 << 18)
        XCTAssertTrue(tap.flagsChanged(keyCode: 62, flags: 0))
    }
    func testOnlyReleaseOfStandaloneRightControlToggles() {
        var tap = RightControlTap()
        XCTAssertFalse(tap.flagsChanged(keyCode: 62, flags: right))
        XCTAssertTrue(tap.flagsChanged(keyCode: 62, flags: 0))
        XCTAssertFalse(tap.flagsChanged(keyCode: 62, flags: 0))
        XCTAssertFalse(tap.flagsChanged(keyCode: 59, flags: 1 | (1 << 18)))
        XCTAssertFalse(tap.flagsChanged(keyCode: 59, flags: 0))
    }
    func testShortcutOrMouseCancelsUntilNextPress() {
        var tap = RightControlTap()
        _ = tap.flagsChanged(keyCode: 62, flags: right)
        tap.cancel()
        XCTAssertFalse(tap.flagsChanged(keyCode: 62, flags: right))
        XCTAssertFalse(tap.flagsChanged(keyCode: 62, flags: 0))
        _ = tap.flagsChanged(keyCode: 62, flags: right)
        XCTAssertTrue(tap.flagsChanged(keyCode: 62, flags: 0))
    }
    func testOtherModifiersBeforeOrDuringPressPreventToggle() {
        for flag: UInt in [1, 1 << 17, 1 << 19, 1 << 20, 1 << 23] {
            var tap = RightControlTap()
            _ = tap.flagsChanged(keyCode: 62, flags: right | flag)
            XCTAssertFalse(tap.flagsChanged(keyCode: 62, flags: flag))
            _ = tap.flagsChanged(keyCode: 62, flags: right)
            _ = tap.flagsChanged(keyCode: 56, flags: right | flag)
            _ = tap.flagsChanged(keyCode: 56, flags: right)
            XCTAssertFalse(tap.flagsChanged(keyCode: 62, flags: 0))
        }
    }
    func testSessionResetPreventsOrphanRelease() {
        var tap = RightControlTap()
        _ = tap.flagsChanged(keyCode: 62, flags: right)
        tap.reset()
        XCTAssertFalse(tap.flagsChanged(keyCode: 62, flags: 0))
    }
    func testRecordedDuplicateTapBurstOnlyTogglesOnce() {
        var tap = RightControlTap()
        // Relative timing from the Codex IMK trace, including full repeated taps.
        let events: [(Double, UInt)] = [
            (0.000, 1 << 18), (0.001, 0),
            (0.006, 1 << 18), (0.008, 0),
            (0.035, 1 << 18), (0.037, 0)
        ]
        var toggles = 0
        for (time, flags) in events {
            if tap.flagsChanged(keyCode: 62, flags: flags, timestamp: 100 + time) { toggles += 1 }
        }
        XCTAssertEqual(toggles, 1)
        XCTAssertFalse(tap.flagsChanged(keyCode: 62, flags: right, timestamp: 100.100))
        XCTAssertTrue(tap.flagsChanged(keyCode: 62, flags: 0, timestamp: 100.150))
    }
    func testRejectedPressCannotToggleAfterBeingHeldAndResetPreservesQuietPeriod() {
        var tap = RightControlTap()
        _ = tap.flagsChanged(keyCode: 62, flags: right, timestamp: 10)
        XCTAssertTrue(tap.flagsChanged(keyCode: 62, flags: 0, timestamp: 10.1))
        tap.reset()
        _ = tap.flagsChanged(keyCode: 62, flags: right, timestamp: 10.105)
        XCTAssertFalse(tap.flagsChanged(keyCode: 62, flags: 0, timestamp: 10.3))
        _ = tap.flagsChanged(keyCode: 62, flags: right, timestamp: 10.4)
        tap.cancel()
        XCTAssertFalse(tap.flagsChanged(keyCode: 62, flags: 0, timestamp: 10.5))
    }

    func testReplayedOriginalEventTimestampsDoNotToggleAgain() {
        var tap = RightControlTap()
        _ = tap.flagsChanged(keyCode: 62, flags: right, timestamp: 20)
        XCTAssertTrue(tap.flagsChanged(keyCode: 62, flags: 0, timestamp: 20.1))
        _ = tap.flagsChanged(keyCode: 62, flags: right, timestamp: 20)
        XCTAssertFalse(tap.flagsChanged(keyCode: 62, flags: 0, timestamp: 20.1))
        _ = tap.flagsChanged(keyCode: 62, flags: right, timestamp: 20.2)
        XCTAssertTrue(tap.flagsChanged(keyCode: 62, flags: 0, timestamp: 20.3))
    }

}
