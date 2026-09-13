import XCTest
import CoreGraphics
@testable import InputCore
final class CandidateGeometryTests: XCTestCase {
    func testBelowCaretAndFlipsAboveBottomEdge() {
        let screen = CGRect(x: 0, y: 30, width: 1000, height: 700)
        let size = CGSize(width: 250, height: 180)
        XCTAssertEqual(CandidateGeometry.frame(size: size, caret: CGRect(x: 100, y: 400, width: 1, height: 20), visible: screen).minY, 214)
        XCTAssertEqual(CandidateGeometry.frame(size: size, caret: CGRect(x: 100, y: 40, width: 1, height: 20), visible: screen).minY, 66)
    }
    func testEdgesAndOversizedContentOnNegativeOriginDisplay() {
        let screen = CGRect(x: -1280, y: -300, width: 1280, height: 800)
        for caret in [CGRect(x: -2, y: 480, width: 1, height: 20), CGRect(x: -1400, y: -400, width: 1, height: 20)] {
            for size in [CGSize(width: 400, height: 200), CGSize(width: 2000, height: 1200)] {
                XCTAssertTrue(screen.contains(CandidateGeometry.frame(size: size, caret: caret, visible: screen)))
            }
        }
    }
}
