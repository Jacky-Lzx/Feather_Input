import XCTest
@testable import InputCore

final class LLMDebugLogTests: XCTestCase {
    func testOptInClearAndLateCompletion() async throws {
        await MainActor.run {
            let log = LLMDebugLog()
            let request = URLRequest(url: URL(string: "http://127.0.0.1:1234/v1/models")!)
            XCTAssertNil(log.begin(request: request, token: "secret"))
            log.enabled = true
            let id = log.begin(request: request, token: "secret")
            XCTAssertEqual(log.entries.count, 1)
            log.enabled = false
            log.enabled = true
            log.finish(id, data: Data("old response".utf8), status: 200, outcome: "success", token: "secret")
            XCTAssertTrue(log.entries.isEmpty)
            let next = log.begin(request: request, token: "secret")
            log.clear()
            log.finish(next, data: Data("old response".utf8), status: 200, outcome: "success", token: "secret")
            XCTAssertTrue(log.entries.isEmpty)
        }
    }
    func testRedactionBoundedHistoryAndResponse() async throws {
        try await MainActor.run {
            let log = LLMDebugLog()
            log.enabled = true
            let token = "secret/with\"quote"
            var request = URLRequest(url: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["reflected": token])
            for _ in 0..<35 { _ = log.begin(request: request, token: token) }
            XCTAssertEqual(log.entries.count, 30)
            XCTAssertTrue(log.entries[0].request.contains("[REDACTED]"))
            XCTAssertFalse(log.entries[0].request.contains("secret"))
            let id = log.entries[0].id
            log.finish(id, data: request.httpBody, status: 401, outcome: "认证失败", token: token)
            XCTAssertTrue(log.entries[0].response.contains("[REDACTED]"))
            XCTAssertTrue(log.entries[0].outcome.contains("401"))
            XCTAssertNotNil(log.entries[0].milliseconds)
            let truncated = LLMDebugLog.display(Data(String(repeating: "中", count: 40_000).utf8), token: "")
            XCTAssertLessThan(truncated.count, 32_100)
            XCTAssertTrue(truncated.contains("截断"))
        }
    }
}
