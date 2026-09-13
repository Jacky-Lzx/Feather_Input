import Foundation
import CRime

public enum InputScheme: String, CaseIterable {
    case full = "luna_pinyin_simp"
    case flypy = "double_pinyin_flypy"
    public var title: String { self == .full ? "全拼" : "小鹤双拼" }
}

// All engine and session access must be serialized on the calling thread.
public final class Engine {
    public init(library: String, shared: String, user: String) throws {
        try FileManager.default.createDirectory(atPath: user, withIntermediateDirectories: true)
        guard feather_start(library, shared, user) != 0 else { throw Failure.libraryUnavailable }
    }
    deinit { feather_stop() }
    public enum Failure: Error { case libraryUnavailable, schemaUnavailable }
    public func session(_ scheme: InputScheme) throws -> Session {
        let id = feather_session(scheme.rawValue)
        guard id != 0 else { throw Failure.schemaUnavailable }
        return Session(id: id, engine: self)
    }
}
public final class Session {
    private let id: UInt
    private let engine: Engine
    fileprivate init(id: UInt, engine: Engine) { self.id = id; self.engine = engine }
    deinit { feather_destroy(id) }
    @discardableResult public func process(_ key: Int32, modifiers: Int32 = 0) -> Bool {
        feather_key(id, key, modifiers) != 0
    }
    @discardableResult public func selectCandidate(at index: Int) -> Bool {
        guard index >= 0, index < candidates.texts.count else { return false }
        return feather_select_candidate(id, Int32(index)) != 0
    }
    public func clear() { feather_clear(id) }
    public func commit() { feather_commit(id) }
    public func setASCII(_ enabled: Bool) { feather_ascii(id, enabled ? 1 : 0) }
    @discardableResult public func select(_ scheme: InputScheme) -> Bool { feather_select(id, scheme.rawValue) != 0 }
    public func takeCommit() -> String? {
        guard let p = feather_take_commit(id) else { return nil }
        defer { feather_free(p) }; return String(cString: p)
    }
    public var preedit: (text: String, cursor: Int) {
        var cursor: Int32 = 0
        guard let p = feather_preedit(id, &cursor) else { return ("", 0) }
        defer { feather_free(p) }
        let text = String(cString: p)
        return (text, Self.utf16Cursor(text, byteOffset: Int(cursor)))
    }
    public static func utf16Cursor(_ text: String, byteOffset: Int) -> Int {
        String(decoding: text.utf8.prefix(max(0, byteOffset)), as: UTF8.self).utf16.count
    }
    public var candidates: (texts: [String], highlight: Int) {
        var pointers = [UnsafeMutablePointer<CChar>?](repeating: nil, count: 10)
        var highlight: Int32 = 0
        let count = feather_candidates(id, &pointers, 10, &highlight)
        let texts = pointers.prefix(Int(count)).compactMap { p -> String? in
            guard let p else { return nil }; defer { feather_free(p) }; return String(cString: p)
        }
        return (texts, Int(highlight))
    }
}
