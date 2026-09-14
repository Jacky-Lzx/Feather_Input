import XCTest
@testable import InputCore
final class CandidateGridTests: XCTestCase {
    func testColumnAndRowBoundaries() {
        XCTAssertEqual(CandidateGrid.move(index: 0, count: 19, rows: 8, horizontal: 1, vertical: 0), 8)
        XCTAssertEqual(CandidateGrid.move(index: 9, count: 19, rows: 8, horizontal: -1, vertical: 0), 1)
        XCTAssertEqual(CandidateGrid.move(index: 7, count: 19, rows: 8, horizontal: 0, vertical: 1), 7)
        XCTAssertEqual(CandidateGrid.move(index: 8, count: 19, rows: 8, horizontal: 0, vertical: -1), 8)
        XCTAssertEqual(CandidateGrid.move(index: 15, count: 19, rows: 8, horizontal: 1, vertical: 0), 18)
        XCTAssertEqual(CandidateGrid.move(index: 18, count: 19, rows: 8, horizontal: 1, vertical: 0), 18)
    }
}
