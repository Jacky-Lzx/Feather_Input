import Foundation

public enum CandidateRanking {
    /// Exact token equality only. Returned indices always refer to the original Rime page.
    public static func order(_ candidates: [String], predictions: [String]) -> [Int] {
        var ranks: [String: Int] = [:]
        for (index, text) in predictions.enumerated() where ranks[text] == nil { ranks[text] = index }
        return candidates.indices.sorted {
            let left = ranks[candidates[$0]] ?? Int.max
            let right = ranks[candidates[$1]] ?? Int.max
            return left == right ? $0 < $1 : left < right
        }
    }
}
