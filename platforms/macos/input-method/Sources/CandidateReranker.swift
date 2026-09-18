import Foundation

enum CandidateReranker {
  static func apply(
    _ result: FeatherScoringResultValue,
    requestID: UInt64,
    revision: UInt64,
    to original: [FeatherCandidateValue]
  ) -> [FeatherCandidateValue]? {
    guard result.requestID == requestID, result.revision == revision,
      result.candidates.count == original.count
    else {
      return nil
    }

    var candidatesByID: [UInt64: FeatherCandidateValue] = [:]
    var originalIndexes: [UInt64: Int] = [:]
    for (index, candidate) in original.enumerated() {
      guard candidate.revision == revision, candidatesByID[candidate.value] == nil else {
        return nil
      }
      candidatesByID[candidate.value] = candidate
      originalIndexes[candidate.value] = index
    }

    var scoredIDs = Set<UInt64>()
    for candidate in result.candidates {
      guard scoredIDs.insert(candidate.value).inserted,
        let originalCandidate = candidatesByID[candidate.value],
        originalCandidate.text == candidate.text,
        candidate.modelScore.isFinite,
        candidate.score.isFinite
      else {
        return nil
      }
    }

    return result.candidates.sorted { left, right in
      if left.score != right.score {
        return left.score > right.score
      }
      return originalIndexes[left.value, default: .max]
        < originalIndexes[right.value, default: .max]
    }.compactMap { candidatesByID[$0.value] }
  }
}
