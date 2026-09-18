import Foundation

@MainActor
final class SmokeScoringRequest: FeatherScoringRequesting {
  private let result: FeatherScoringResultValue?
  private(set) var pollIdentities: [(UInt64, UInt64)] = []
  private(set) var cancelCount = 0
  private(set) var closeCount = 0

  init(result: FeatherScoringResultValue?) {
    self.result = result
  }

  func poll(currentRequestID: UInt64, currentRevision: UInt64) throws -> FeatherScoringState {
    pollIdentities.append((currentRequestID, currentRevision))
    guard let result else { return .pending }
    return .ready(result)
  }

  func cancel() throws {
    cancelCount += 1
  }

  func close() {
    closeCount += 1
  }
}
