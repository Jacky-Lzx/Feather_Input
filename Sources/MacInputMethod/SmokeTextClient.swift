import AppKit
import InputMethodKit

/// In-process IMK client used only by --smoke-test; never edits another app.
final class SmokeTextClient: NSObject, IMKTextInput {
    var committed = ""
    var marked = ""
    var ignoresMarkedText = false
    var caretRectangle = NSRect(x: 300, y: 400, width: 1, height: 20)
    var exposesDocument = false
    var documentSelection: NSRange?
    var selectionUnavailable = false
    var textInputUnavailable = false
    var unicodeSupported = true
    var clientBundleIdentifier = "im.feather.smoke-client"
    func insertText(_ string: Any!, replacementRange: NSRange) { committed += string as? String ?? ""; marked = "" }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) { if !ignoresMarkedText { marked = string as? String ?? "" } }
    func selectedRange() -> NSRange {
        if selectionUnavailable || textInputUnavailable { return NSRange(location: NSNotFound, length: 0) }
        return documentSelection ?? NSRange(location: committed.utf16.count, length: 0)
    }
    func markedRange() -> NSRange { NSRange(location: committed.utf16.count, length: marked.utf16.count) }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        guard exposesDocument, range.location >= 0, range.location <= committed.utf16.count,
              range.length <= committed.utf16.count - range.location else { return nil }
        return NSAttributedString(string: (committed as NSString).substring(with: range))
    }
    func length() -> Int { committed.utf16.count + marked.utf16.count }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle rect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! {
        rect.pointee = textInputUnavailable ? .zero : caretRectangle
        return [:]
    }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed name: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { unicodeSupported }
    func bundleIdentifier() -> String! { clientBundleIdentifier }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "feather-smoke-client" }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        guard let text = attributedSubstring(from: range) else { return nil }
        actualRange?.pointee = range
        return text.string
    }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect {
        actualRange?.pointee = range
        return textInputUnavailable ? .zero : caretRectangle
    }
}
