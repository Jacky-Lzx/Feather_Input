import XCTest
@testable import InputCore
final class CandidateGridTests: XCTestCase {
    func testNumbersReferToHighlightedColumn() {
        XCTAssertEqual(CandidateGrid.numberedIndex(number: 3, highlight: 8, count: 80, rows: 7), 9)
        XCTAssertEqual(CandidateGrid.numberedIndex(number: 7, highlight: 35, count: 80, rows: 7), 41)
        XCTAssertNil(CandidateGrid.numberedIndex(number: 8, highlight: 8, count: 80, rows: 7))
        XCTAssertNil(CandidateGrid.numberedIndex(number: 3, highlight: 14, count: 16, rows: 7))
        XCTAssertEqual(CandidateGrid.numberedIndex(number: 2, highlight: 14, count: 16, rows: 7), 15)
    }
    func testFiveColumnPages() {
        let next = CandidateGrid.move(index: 35, count: 83, rows: 8, horizontal: 1, vertical: 0)
        XCTAssertEqual(next, 43)
        XCTAssertEqual(CandidateGrid.pageRange(index: 35, count: 83, rows: 8), 0..<40)
        XCTAssertEqual(CandidateGrid.pageRange(index: next, count: 83, rows: 8), 40..<80)
        let previous = CandidateGrid.move(index: next, count: 83, rows: 8, horizontal: -1, vertical: 0)
        XCTAssertEqual(previous, 35)
        XCTAssertEqual(CandidateGrid.pageRange(index: 82, count: 83, rows: 8), 80..<83)
    }
    func testColumnAndRowBoundaries() {
        XCTAssertEqual(CandidateGrid.move(index: 0, count: 19, rows: 8, horizontal: 1, vertical: 0), 8)
        XCTAssertEqual(CandidateGrid.move(index: 9, count: 19, rows: 8, horizontal: -1, vertical: 0), 1)
        XCTAssertEqual(CandidateGrid.move(index: 7, count: 19, rows: 8, horizontal: 0, vertical: 1), 7)
        XCTAssertEqual(CandidateGrid.move(index: 8, count: 19, rows: 8, horizontal: 0, vertical: -1), 8)
        XCTAssertEqual(CandidateGrid.move(index: 15, count: 19, rows: 8, horizontal: 1, vertical: 0), 18)
        XCTAssertEqual(CandidateGrid.move(index: 18, count: 19, rows: 8, horizontal: 1, vertical: 0), 18)
    }
}
