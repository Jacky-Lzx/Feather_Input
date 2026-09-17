import Foundation

@MainActor
final class SmokeGenerationRequest: FeatherGenerationRequesting {
  private let result: FeatherGenerationResultValue?
  private var pendingPolls: Int
  private(set) var pollIdentities: [(UInt64, UInt64)] = []
  private(set) var cancelCount = 0
  private(set) var closeCount = 0

  init(result: FeatherGenerationResultValue?, pendingPolls: Int = 0) {
    self.result = result
    self.pendingPolls = pendingPolls
  }

  func poll(currentRequestID: UInt64, currentRevision: UInt64) throws
    -> FeatherGenerationState
  {
    pollIdentities.append((currentRequestID, currentRevision))
    if pendingPolls > 0 {
      pendingPolls -= 1
      return .pending
    }
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
