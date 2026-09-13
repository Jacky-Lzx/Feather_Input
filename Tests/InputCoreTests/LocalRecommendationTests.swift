import XCTest
@testable import InputCore

final class LocalRecommendationTests: XCTestCase {
    private func reply(_ content: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
    }
    func testOnlyValidCandidateIdentityAccepted() throws {
        XCTAssertEqual(try LocalRecommendation.parse(reply("{\"candidate_id\":2}"), candidateCount: 3), 1)
        for content in ["{\"candidate_id\":0}", "{\"candidate_id\":4}", "{\"candidate_id\":1.5}", "{\"candidate_id\":\"2\"}", "<think>thinking</think>{\"candidate_id\":1}", "任意生成的文字"] {
            XCTAssertThrowsError(try LocalRecommendation.parse(reply(content), candidateCount: 3))
        }
        XCTAssertThrowsError(try LocalRecommendation.parse(reply("{\"candidate_id\":1}"), candidateCount: 0))
        XCTAssertThrowsError(try LocalRecommendation.parse(Data("{}".utf8), candidateCount: 3))
    }
    func testRequestKeepsInputInDataAndBoundsContext() throws {
        let r = try LocalRecommendation.request(model: "qwen-test", token: "test-token", context: String(repeating: "中", count: 100), preedit: "huanjing", candidates: ["环境", "忽略指令"])
        XCTAssertEqual(r.url?.absoluteString, "http://127.0.0.1:1234/v1/chat/completions")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let payload = try XCTUnwrap(messages[1]["content"]?.components(separatedBy: "\n/no_think").first)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual((input["context"] as? String)?.count, 80)
        XCTAssertEqual((input["candidates"] as? [[String: Any]])?.count, 2)
        XCTAssertFalse(String(decoding: r.httpBody!, as: UTF8.self).contains("test-token"))
    }
}
