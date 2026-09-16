import Foundation

enum TextCoordinates {
  static func utf16Offset(in text: String, utf8Offset: Int) -> Int {
    guard utf8Offset >= 0, utf8Offset <= text.utf8.count else { return text.utf16.count }
    let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: utf8Offset)
    guard let index = String.Index(utf8Index, within: text) else { return text.utf16.count }
    return text.utf16.distance(from: text.utf16.startIndex, to: index)
  }
}
