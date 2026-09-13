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
}
