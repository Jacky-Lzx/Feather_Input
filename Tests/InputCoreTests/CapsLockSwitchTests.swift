import XCTest
@testable import InputCore
final class CapsLockSwitchTests: XCTestCase {
    func testBothLatchEdgesToggleOnce() {
        var tracker = CapsLockSwitch()
        XCTAssertTrue(tracker.flagsChanged(keyCode: 57, flags: 1 << 16))
        XCTAssertFalse(tracker.flagsChanged(keyCode: 57, flags: 1 << 16))
        XCTAssertTrue(tracker.flagsChanged(keyCode: 57, flags: 0))
        XCTAssertFalse(tracker.flagsChanged(keyCode: 57, flags: 0))
    }
    func testActivationSeedsLatchAndOtherModifiersDoNotSwitch() {
        var tracker = CapsLockSwitch()
        tracker.reset(isLocked: true)
        XCTAssertFalse(tracker.flagsChanged(keyCode: 57, flags: 1 << 16))
        XCTAssertTrue(tracker.flagsChanged(keyCode: 57, flags: 0))
        XCTAssertFalse(tracker.flagsChanged(keyCode: 57, flags: (1 << 16) | (1 << 20)))
        XCTAssertFalse(tracker.flagsChanged(keyCode: 55, flags: 1 << 16))
        XCTAssertTrue(tracker.flagsChanged(keyCode: 0, flags: 0))
    }
}
