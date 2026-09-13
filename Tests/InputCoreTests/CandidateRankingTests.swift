import XCTest
@testable import InputCore

final class CandidateRankingTests: XCTestCase {
    func testExactIntersectionProbabilityOrderAndStableRemainder() {
        XCTAssertEqual(CandidateRanking.order(["幻境", "环境", "环径", "环境保护"], predictions: ["保护", "环境", "幻境"]), [1, 0, 2, 3])
        XCTAssertEqual(CandidateRanking.order(["环", "环境保护"], predictions: ["环境"]), [0, 1])
        XCTAssertEqual(CandidateRanking.order(["环境", "幻境", "环境"], predictions: ["环境", "环境"]), [0, 2, 1])
        XCTAssertEqual(CandidateRanking.order(["环境", "幻境"], predictions: []), [0, 1])
    }
}
