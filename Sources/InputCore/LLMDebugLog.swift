import Foundation
import Combine

@MainActor
public final class LLMDebugLog: ObservableObject {
    public static let shared = LLMDebugLog()
    public struct Entry: Identifiable {
        public let id: UUID
        public let started: Date
        public let endpoint: String
        public let request: String
        public var response = "等待返回…"
        public var outcome = "请求中"
        public var milliseconds: Int?
    }
    @Published public var enabled = false {
        didSet { if !enabled { clear() } }
    }
    @Published public private(set) var entries: [Entry] = []
    public init() {}
    public func clear() { entries.removeAll() }
    public func begin(request: URLRequest, token: String) -> UUID? {
        guard enabled else { return nil }
        let id = UUID()
        entries.insert(Entry(id: id, started: Date(), endpoint: "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")",
                             request: Self.display(request.httpBody, token: token)), at: 0)
        if entries.count > 30 { entries.removeLast(entries.count - 30) }
        return id
    }
    public func finish(_ id: UUID?, data: Data?, status: Int?, outcome: String, token: String) {
        guard enabled, let id, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].response = Self.display(data, token: token)
        entries[index].outcome = (status.map { "HTTP \($0) · " } ?? "") + outcome
        entries[index].milliseconds = Int(Date().timeIntervalSince(entries[index].started) * 1000)
    }
    public static func display(_ data: Data?, token: String) -> String {
        guard let data else { return "（无正文）" }
        let formatted: Data
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) {
            formatted = pretty
        } else { formatted = data }
        var text = String(decoding: formatted, as: UTF8.self)
        if !token.isEmpty {
            text = text.replacingOccurrences(of: token, with: "[REDACTED]")
            if let encoded = try? JSONSerialization.data(withJSONObject: token, options: [.fragmentsAllowed]),
               let escaped = String(data: encoded, encoding: .utf8) {
                text = text.replacingOccurrences(of: String(escaped.dropFirst().dropLast()), with: "[REDACTED]")
            }
        }
        let limit = 32_000
        return text.count > limit ? String(text.prefix(limit)) + "\n…（显示已截断）" : text
    }
}
