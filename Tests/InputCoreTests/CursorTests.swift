import XCTest
@testable import InputCore
final class CursorTests: XCTestCase {
    func testRimeByteCursorToClientUTF16() {
        XCTAssertEqual(Session.utf16Cursor("你 hao", byteOffset: 3), 1)
        XCTAssertEqual(Session.utf16Cursor("你好", byteOffset: 6), 2)
        XCTAssertEqual(Session.utf16Cursor("😀a", byteOffset: 4), 2)
        XCTAssertEqual(Session.utf16Cursor("ni hao", byteOffset: 3), 3)
    }
}
