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
    func testContinuationRejectsEchoesMultilineAndOversizedOutput() throws {
        func completion(_ text: String) throws -> Data {
            let inner = try JSONSerialization.data(withJSONObject: ["continuation": text])
            return try reply(String(decoding: inner, as: UTF8.self))
        }
        XCTAssertEqual(try LocalRecommendation.parseContinuation(completion("开会讨论一下"), context: "我们明天下午"), "开会讨论一下")
        for text in ["", "12345678901234567890", "。。。", "我们明天下午开会", "第一行\n第二行", "hello\tworld", String(repeating: "中", count: 25), "<think>先思考</think>"] {
            XCTAssertThrowsError(try LocalRecommendation.parseContinuation(completion(text), context: "我们明天下午"))
        }
    }

    func testMLXFiltersInvalidCandidatesAndPreservesDistinctOrder() throws {
        let data = try JSONSerialization.data(withJSONObject: ["candidates": [
            ["text": "户外活动。", "score": -0.8],
            ["text": "户外活动。", "score": -1.0],
            ["text": "第一行\n第二行", "score": -1.1],
            ["text": "出门散步，", "score": -1.2],
            ["text": "错误概率", "score": 0.5]
        ]])
        XCTAssertEqual(try LocalRecommendation.parseMLXContinuations(data, context: "适合"), ["户外活动。", "出门散步，"])
        XCTAssertThrowsError(try LocalRecommendation.parseMLXContinuations(Data("{\"candidates\":[]}".utf8), context: "适合"))
    }
    func testNextTokenPreservesPunctuationWhitespaceAndRepeatedTokens() throws {
        let texts = ["，", " ", "你好", " world", "<"]
        let data = try JSONSerialization.data(withJSONObject: ["candidates": texts.map { ["text": $0, "score": -1.0] as [String: Any] }])
        XCTAssertEqual(try LocalRecommendation.parseMLXContinuations(data, context: "你好"), texts)
    }
    func testConfigurableMLXCountBounds() throws {
        let data = try JSONSerialization.data(withJSONObject: ["candidates": (0..<25).map { ["text": "词\($0)", "score": -1.0] as [String: Any] }])
        for (requested, expected) in [(1, 1), (9, 9), (20, 20), (100, 20), (0, 1)] {
            XCTAssertEqual(try LocalRecommendation.parseMLXContinuations(data, context: "", count: requested).count, expected)
        }
    }
    func testLLMRankRetainsPositionsOfFilteredTokens() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "top_tokens": [["text": "<eos>"], ["text": "\n"], ["text": "环境"], ["text": "，"]],
            "candidates": [["text": "环境", "score": -1.0], ["text": "，", "score": -2.0]]
        ])
        XCTAssertEqual(try LocalRecommendation.parseMLXRankedTokens(data, context: ""),
                       [.init(text: "环境", rank: 3), .init(text: "，", rank: 4)])
    }
    func testCandidateScoresValidateIdentitiesAndSortStably() throws {
        func data(_ rows: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["candidates": rows]) }
        let texts = ["幻境", "环境", "环径"]
        XCTAssertEqual(try LocalRecommendation.parseCandidateScores(data([
            ["id": 0, "text": "幻境", "score": -8.0], ["id": 2, "text": "环径", "score": -8.0],
            ["id": 1, "text": "环境", "score": -2.0, "lm_score": -1.5]
        ]), candidates: texts), [.init(text: "环境", rank: 1, modelScore: -1.5, fusionScore: -2, sourceIndex: 1), .init(text: "幻境", rank: 2, fusionScore: -8, sourceIndex: 0), .init(text: "环径", rank: 3, fusionScore: -8, sourceIndex: 2)])
        for row in [["id": 1, "text": "环境", "score": -1.0], ["id": 0, "text": "其他", "score": -1.0], ["id": 0, "text": "环境", "score": 1.0]] as [[String: Any]] {
            XCTAssertThrowsError(try LocalRecommendation.parseCandidateScores(data([row]), candidates: ["环境"]))
        }
        XCTAssertThrowsError(try LocalRecommendation.parseCandidateScores(data([]), candidates: texts))
    }
}
