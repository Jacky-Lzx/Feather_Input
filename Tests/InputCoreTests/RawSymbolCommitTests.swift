import XCTest
@testable import InputCore

final class RawSymbolCommitTests: XCTestCase {
    func testPrintableSymbolsCommitRawLetterComposition() {
        for raw in ["github", "nihao", "nihc"] {
            for symbol in [".", ",", "@", "-", "_", "/", ":", "'", "(", ")"] {
                XCTAssertTrue(RawSymbolCommit.shouldCommit(rawInput: raw, symbol: symbol))
            }
        }
    }

    func testWhitespaceAlphanumericAndNonLetterCompositionKeepRimeBehavior() {
        XCTAssertFalse(RawSymbolCommit.shouldCommit(rawInput: "nihao", symbol: " "))
        XCTAssertFalse(RawSymbolCommit.shouldCommit(rawInput: "github", symbol: "1"))
        XCTAssertFalse(RawSymbolCommit.shouldCommit(rawInput: "git hub", symbol: "."))
        XCTAssertFalse(RawSymbolCommit.shouldCommit(rawInput: "abc1", symbol: "."))
        XCTAssertFalse(RawSymbolCommit.shouldCommit(rawInput: "", symbol: "."))
    }
}
