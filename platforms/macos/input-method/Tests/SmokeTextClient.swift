import AppKit
import InputMethodKit

final class SmokeTextClient: NSObject, IMKTextInput {
  var committed = ""
  var marked = ""
  var markedSelection = NSRange(location: 0, length: 0)
  var selectionAvailable = true

  func insertText(_ string: Any!, replacementRange: NSRange) {
    committed += string as? String ?? ""
    marked = ""
  }

  func setMarkedText(
    _ string: Any!,
    selectionRange: NSRange,
    replacementRange: NSRange
  ) {
    marked = string as? String ?? ""
    markedSelection = selectionRange
  }

  func selectedRange() -> NSRange {
    selectionAvailable
      ? NSRange(location: committed.utf16.count, length: 0)
      : NSRange(location: NSNotFound, length: 0)
  }

  func markedRange() -> NSRange {
    NSRange(location: committed.utf16.count, length: marked.utf16.count)
  }

  func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
  func length() -> Int { committed.utf16.count + marked.utf16.count }

  func characterIndex(
    for point: NSPoint,
    tracking mappingMode: IMKLocationToOffsetMappingMode,
    inMarkedRange: UnsafeMutablePointer<ObjCBool>!
  ) -> Int { 0 }

  func attributes(
    forCharacterIndex index: Int,
    lineHeightRectangle rect: UnsafeMutablePointer<NSRect>!
  ) -> [AnyHashable: Any]! {
    rect.pointee = NSRect(x: 100, y: 100, width: 1, height: 20)
    return [:]
  }

  func validAttributesForMarkedText() -> [Any]! { [] }
  func overrideKeyboard(withKeyboardNamed name: String!) {}
  func selectMode(_ modeIdentifier: String!) {}
  func supportsUnicode() -> Bool { true }
  func bundleIdentifier() -> String! { "im.feather.inputmethod.rustdev.smoke" }
  func windowLevel() -> CGWindowLevel { 0 }
  func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
  func uniqueClientIdentifierString() -> String! { "feather-rust-dev-smoke" }

  func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { nil }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect {
    actualRange?.pointee = range
    return NSRect(x: 100, y: 100, width: 1, height: 20)
  }
}
