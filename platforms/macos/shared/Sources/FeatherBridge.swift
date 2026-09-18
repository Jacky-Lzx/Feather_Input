import FeatherIME
import Foundation

struct FeatherCandidateValue: Equatable {
  let revision: UInt64
  let value: UInt64
  let text: String
}

struct FeatherResponseValue {
  let handled: Bool
  let active: Bool
  let directMode: Bool
  let commit: String?
  let preedit: String
  let cursorUTF8: Int
  let revision: UInt64
  let candidates: [FeatherCandidateValue]
  let highlighted: Int?
}

struct FeatherCandidateSliceValue {
  let revision: UInt64
  let offset: Int
  let candidates: [FeatherCandidateValue]
  let hasMore: Bool
}

struct FeatherGeneratedCandidateValue: Equatable {
  let text: String
  let score: Double
}

struct FeatherGenerationResultValue: Equatable {
  let requestID: UInt64
  let revision: UInt64
  let candidates: [FeatherGeneratedCandidateValue]
  let elapsedMilliseconds: UInt64
  let truncated: Bool
}

enum FeatherGenerationState: Equatable {
  case pending
  case ready(FeatherGenerationResultValue)
  case failed
  case cancelled
  case stale
}

enum FeatherScoreNormalization: UInt32 {
  case character = 1
  case token
  case none
}

struct FeatherScoredCandidateValue: Equatable {
  let value: UInt64
  let text: String
  let modelScore: Double
  let score: Double
}

struct FeatherScoringResultValue: Equatable {
  let requestID: UInt64
  let revision: UInt64
  let candidates: [FeatherScoredCandidateValue]
  let elapsedMilliseconds: UInt64
}

enum FeatherScoringState: Equatable {
  case pending
  case ready(FeatherScoringResultValue)
  case failed
  case cancelled
  case stale
}

@MainActor
protocol FeatherGenerationRequesting: AnyObject {
  func poll(currentRequestID: UInt64, currentRevision: UInt64) throws
    -> FeatherGenerationState
  func cancel() throws
  func close()
}

@MainActor
protocol FeatherScoringRequesting: AnyObject {
  func poll(currentRequestID: UInt64, currentRevision: UInt64) throws
    -> FeatherScoringState
  func cancel() throws
  func close()
}

enum FeatherBridgeError: LocalizedError {
  case unsupportedABI(UInt32)
  case missingCapabilities(UInt64)
  case sessionCreationFailed
  case sessionClosed
  case callFailed(operation: String, status: UInt32, code: UInt32, message: String?)
  case invalidSuccess(operation: String)

  var errorDescription: String? {
    switch self {
    case .unsupportedABI(let version):
      return "不支持 Feather C ABI 版本：\(version)"
    case .missingCapabilities(let missing):
      return "Feather C ABI 缺少 Harness 所需能力：0x\(String(missing, radix: 16))"
    case .sessionCreationFailed:
      return "Feather C ABI 返回成功，但没有创建 librime 会话。"
    case .sessionClosed:
      return "Feather 会话已经关闭。"
    case .callFailed(let operation, let status, let code, let message):
      let detail = message.map { "：\($0)" } ?? ""
      return "Feather C ABI 调用失败（\(operation)，status=\(status)，code=\(code)）\(detail)"
    case .invalidSuccess(let operation):
      return "Feather C ABI 返回成功但没有提供结果：\(operation)"
    }
  }
}

enum FeatherKey: UInt32 {
  case text = 1
  case backspace
  case delete
  case space
  case enter
  case escape
  case left
  case right
  case up
  case down
  case pageUp
  case pageDown
  case toggleMode
}

@MainActor
final class FeatherSession {
  private static let expectedABI: UInt32 = 2
  private static let requiredCapabilities: UInt64 = 0b1_1111
  private static let candidateSlicesCapability: UInt64 = 1 << 5
  private static let schemaSelectionCapability: UInt64 = 1 << 6
  private static let pageSizeCapability: UInt64 = 1 << 7
  private static let englishCandidateMinimumCapability: UInt64 = 1 << 8
  private static let asyncMLXGenerationCapability: UInt64 = 1 << 9
  private static let asyncMLXScoringCapability: UInt64 = 1 << 11

  private var handle: OpaquePointer?
  private let capabilities: UInt64

  init(sharedData: URL, userData: URL, schema: String) throws {
    let version = feather_ime_abi_version()
    guard version == Self.expectedABI else {
      throw FeatherBridgeError.unsupportedABI(version)
    }

    let capabilities = feather_ime_capabilities()
    let missing = Self.requiredCapabilities & ~capabilities
    guard missing == 0 else {
      throw FeatherBridgeError.missingCapabilities(missing)
    }

    var newHandle: OpaquePointer?
    var ffiError: UnsafeMutablePointer<FeatherError>?
    let status = sharedData.path.withCString { sharedPath in
      userData.path.withCString { userPath in
        schema.withCString { schemaName in
          feather_ime_new_rime(
            sharedPath,
            userPath,
            schemaName,
            &newHandle,
            &ffiError
          )
        }
      }
    }

    do {
      try Self.check(status: status, error: ffiError, operation: "new rime session")
    } catch {
      if let newHandle {
        var closeError: UnsafeMutablePointer<FeatherError>?
        _ = feather_ime_close(newHandle, &closeError)
        feather_error_free(closeError)
        feather_ime_free(newHandle)
      }
      throw error
    }
    guard let newHandle else {
      throw FeatherBridgeError.sessionCreationFailed
    }
    self.capabilities = capabilities
    handle = newHandle
  }

  deinit {
    if let handle {
      var ffiError: UnsafeMutablePointer<FeatherError>?
      _ = feather_ime_close(handle, &ffiError)
      feather_error_free(ffiError)
      feather_ime_free(handle)
    }
  }

  func close() throws {
    guard let handle else { return }

    var ffiError: UnsafeMutablePointer<FeatherError>?
    let status = feather_ime_close(handle, &ffiError)
    self.handle = nil
    feather_ime_free(handle)
    try Self.check(status: status, error: ffiError, operation: "close")
  }

  func activate() throws -> FeatherResponseValue {
    try perform("activate") { handle, response, error in
      feather_ime_activate(handle, &response, &error)
    }
  }

  func deactivate() throws -> FeatherResponseValue {
    try perform("deactivate") { handle, response, error in
      feather_ime_deactivate(handle, &response, &error)
    }
  }

  func setMode(direct: Bool) throws -> FeatherResponseValue {
    try perform("set mode") { handle, response, error in
      feather_ime_set_mode(handle, direct ? 1 : 0, &response, &error)
    }
  }

  func setSchema(_ schema: String) throws -> FeatherResponseValue {
    let missing = Self.schemaSelectionCapability & ~capabilities
    guard missing == 0 else {
      throw FeatherBridgeError.missingCapabilities(missing)
    }
    return try perform("set schema") { handle, response, error in
      schema.withCString { schemaName in
        feather_ime_set_schema(handle, schemaName, &response, &error)
      }
    }
  }

  func setPageSize(_ pageSize: Int) throws -> FeatherResponseValue {
    let missing = Self.pageSizeCapability & ~capabilities
    guard missing == 0 else {
      throw FeatherBridgeError.missingCapabilities(missing)
    }
    return try perform("set page size") { handle, response, error in
      feather_ime_set_page_size(handle, pageSize, &response, &error)
    }
  }

  func setEnglishCandidateMinimum(_ minimum: Int) throws -> FeatherResponseValue {
    let missing = Self.englishCandidateMinimumCapability & ~capabilities
    guard missing == 0 else {
      throw FeatherBridgeError.missingCapabilities(missing)
    }
    return try perform("set English candidate minimum") { handle, response, error in
      feather_ime_set_english_candidate_minimum(handle, minimum, &response, &error)
    }
  }

  func send(_ key: FeatherKey) throws -> FeatherResponseValue {
    try perform("key \(key)") { handle, response, error in
      feather_ime_key(handle, key.rawValue, nil, 0, &response, &error)
    }
  }

  func send(text: String) throws -> FeatherResponseValue {
    let bytes = Array(text.utf8)
    return try perform("text") { handle, response, error in
      bytes.withUnsafeBufferPointer { buffer in
        feather_ime_key(
          handle,
          FeatherKey.text.rawValue,
          buffer.baseAddress,
          buffer.count,
          &response,
          &error
        )
      }
    }
  }

  func select(_ candidate: FeatherCandidateValue) throws -> FeatherResponseValue {
    try perform("select candidate") { handle, response, error in
      feather_ime_select_candidate(
        handle,
        candidate.revision,
        candidate.value,
        &response,
        &error
      )
    }
  }

  func candidateSlice(revision: UInt64, offset: Int, limit: Int) throws
    -> FeatherCandidateSliceValue
  {
    let missing = Self.candidateSlicesCapability & ~capabilities
    guard missing == 0 else {
      throw FeatherBridgeError.missingCapabilities(missing)
    }
    let handle = try requireHandle()
    var slice: UnsafeMutablePointer<FeatherCandidateSlice>?
    var ffiError: UnsafeMutablePointer<FeatherError>?
    let status = feather_ime_candidate_slice(
      handle,
      revision,
      offset,
      limit,
      &slice,
      &ffiError
    )
    do {
      try Self.check(status: status, error: ffiError, operation: "candidate slice")
    } catch {
      feather_ime_candidate_slice_free(slice)
      throw error
    }
    guard let slice else {
      throw FeatherBridgeError.invalidSuccess(operation: "candidate slice")
    }
    defer { feather_ime_candidate_slice_free(slice) }

    let value = slice.pointee
    let candidates: [FeatherCandidateValue]
    if let base = value.candidates, value.candidate_count > 0 {
      candidates = UnsafeBufferPointer(start: base, count: value.candidate_count).map {
        FeatherCandidateValue(
          revision: $0.revision,
          value: $0.value,
          text: $0.text.map(String.init(cString:)) ?? ""
        )
      }
    } else {
      candidates = []
    }
    return FeatherCandidateSliceValue(
      revision: value.revision,
      offset: value.offset,
      candidates: candidates,
      hasMore: value.has_more != 0
    )
  }

  func startGeneration(
    requestID: UInt64,
    revision: UInt64,
    context: String,
    input: String,
    schema: String,
    count: Int
  ) throws -> FeatherGenerationRequest {
    let missing = Self.asyncMLXGenerationCapability & ~capabilities
    guard missing == 0 else {
      throw FeatherBridgeError.missingCapabilities(missing)
    }

    var request: OpaquePointer?
    var ffiError: UnsafeMutablePointer<FeatherError>?
    let status = context.withCString { contextValue in
      input.withCString { inputValue in
        schema.withCString { schemaValue in
          feather_ai_generate_start(
            requestID,
            revision,
            contextValue,
            inputValue,
            schemaValue,
            count,
            &request,
            &ffiError
          )
        }
      }
    }
    do {
      try Self.check(status: status, error: ffiError, operation: "start MLX generation")
    } catch {
      feather_ai_request_free(request)
      throw error
    }
    guard let request else {
      throw FeatherBridgeError.invalidSuccess(operation: "start MLX generation")
    }
    return FeatherGenerationRequest(handle: request)
  }

  func startScoring(
    requestID: UInt64,
    revision: UInt64,
    context: String,
    preedit: String,
    candidates: [FeatherCandidateValue],
    weight: Double,
    normalization: FeatherScoreNormalization
  ) throws -> FeatherScoringRequest {
    let missing = Self.asyncMLXScoringCapability & ~capabilities
    guard missing == 0 else {
      throw FeatherBridgeError.missingCapabilities(missing)
    }

    let textPointers = candidates.map { strdup($0.text) }
    defer {
      for pointer in textPointers {
        free(pointer)
      }
    }
    guard textPointers.allSatisfy({ $0 != nil }) else {
      throw FeatherBridgeError.invalidSuccess(operation: "copy MLX scoring candidates")
    }
    let inputs = zip(candidates, textPointers).map { candidate, text in
      FeatherAiScoringInput(value: candidate.value, text: UnsafePointer(text))
    }
    var request: OpaquePointer?
    var ffiError: UnsafeMutablePointer<FeatherError>?
    let status = context.withCString { contextValue in
      preedit.withCString { preeditValue in
        inputs.withUnsafeBufferPointer { buffer in
          feather_ai_score_start(
            requestID,
            revision,
            contextValue,
            preeditValue,
            buffer.baseAddress,
            buffer.count,
            weight,
            normalization.rawValue,
            &request,
            &ffiError
          )
        }
      }
    }
    do {
      try Self.check(status: status, error: ffiError, operation: "start MLX scoring")
    } catch {
      feather_ai_scoring_request_free(request)
      throw error
    }
    guard let request else {
      throw FeatherBridgeError.invalidSuccess(operation: "start MLX scoring")
    }
    return FeatherScoringRequest(handle: request)
  }

  private func requireHandle() throws -> OpaquePointer {
    guard let handle else {
      throw FeatherBridgeError.sessionClosed
    }
    return handle
  }

  private func perform(
    _ operation: String,
    call: (
      OpaquePointer,
      inout UnsafeMutablePointer<FeatherResponse>?,
      inout UnsafeMutablePointer<FeatherError>?
    ) -> FeatherStatus
  ) throws -> FeatherResponseValue {
    let handle = try requireHandle()
    var response: UnsafeMutablePointer<FeatherResponse>?
    var ffiError: UnsafeMutablePointer<FeatherError>?
    let status = call(handle, &response, &ffiError)
    do {
      try Self.check(status: status, error: ffiError, operation: operation)
    } catch {
      feather_ime_response_free(response)
      throw error
    }

    guard let response else {
      throw FeatherBridgeError.invalidSuccess(operation: operation)
    }
    return consume(response)
  }

  fileprivate static func check(
    status: FeatherStatus,
    error: UnsafeMutablePointer<FeatherError>?,
    operation: String
  ) throws {
    defer { feather_error_free(error) }
    guard status != 0 else {
      if error != nil {
        throw FeatherBridgeError.invalidSuccess(operation: "\(operation)（意外错误对象）")
      }
      return
    }

    let code = error?.pointee.code ?? status
    let message = error?.pointee.message.map(String.init(cString:))
    throw FeatherBridgeError.callFailed(
      operation: operation,
      status: status,
      code: code,
      message: message
    )
  }

  private func consume(_ pointer: UnsafeMutablePointer<FeatherResponse>) -> FeatherResponseValue {
    defer { feather_ime_response_free(pointer) }

    let response = pointer.pointee
    let candidates: [FeatherCandidateValue]
    if let base = response.candidates, response.candidate_count > 0 {
      let buffer = UnsafeBufferPointer(start: base, count: response.candidate_count)
      candidates = buffer.map { candidate in
        FeatherCandidateValue(
          revision: candidate.revision,
          value: candidate.value,
          text: candidate.text.map(String.init(cString:)) ?? ""
        )
      }
    } else {
      candidates = []
    }

    return FeatherResponseValue(
      handled: response.handled != 0,
      active: response.active != 0,
      directMode: response.mode != 0,
      commit: response.commit.map(String.init(cString:)),
      preedit: response.preedit.map(String.init(cString:)) ?? "",
      cursorUTF8: response.cursor_utf8,
      revision: response.revision,
      candidates: candidates,
      highlighted: response.highlighted >= 0 ? Int(response.highlighted) : nil
    )
  }
}

@MainActor
final class FeatherGenerationRequest: FeatherGenerationRequesting {
  private var handle: OpaquePointer?

  fileprivate init(handle: OpaquePointer) {
    self.handle = handle
  }

  deinit {
    feather_ai_request_free(handle)
  }

  func poll(currentRequestID: UInt64, currentRevision: UInt64) throws
    -> FeatherGenerationState
  {
    guard let handle else {
      return .cancelled
    }
    var rawState = FEATHER_AI_REQUEST_PENDING.rawValue
    var result: UnsafeMutablePointer<FeatherAiResult>?
    var ffiError: UnsafeMutablePointer<FeatherError>?
    let status = feather_ai_request_poll(
      handle,
      currentRequestID,
      currentRevision,
      &rawState,
      &result,
      &ffiError
    )
    do {
      try FeatherSession.check(status: status, error: ffiError, operation: "poll MLX generation")
    } catch {
      feather_ai_result_free(result)
      throw error
    }

    switch rawState {
    case FEATHER_AI_REQUEST_PENDING.rawValue:
      guard result == nil else {
        feather_ai_result_free(result)
        throw FeatherBridgeError.invalidSuccess(operation: "pending MLX generation")
      }
      return .pending
    case FEATHER_AI_REQUEST_READY.rawValue:
      guard let result else {
        throw FeatherBridgeError.invalidSuccess(operation: "ready MLX generation")
      }
      return .ready(consume(result))
    case FEATHER_AI_REQUEST_FAILED.rawValue:
      feather_ai_result_free(result)
      return .failed
    case FEATHER_AI_REQUEST_CANCELLED.rawValue:
      feather_ai_result_free(result)
      return .cancelled
    case FEATHER_AI_REQUEST_STALE.rawValue:
      feather_ai_result_free(result)
      return .stale
    default:
      feather_ai_result_free(result)
      throw FeatherBridgeError.invalidSuccess(
        operation: "unknown MLX generation state \(rawState)"
      )
    }
  }

  func cancel() throws {
    guard let handle else { return }
    var ffiError: UnsafeMutablePointer<FeatherError>?
    let status = feather_ai_request_cancel(handle, &ffiError)
    try FeatherSession.check(status: status, error: ffiError, operation: "cancel MLX generation")
  }

  func close() {
    guard let handle else { return }
    feather_ai_request_free(handle)
    self.handle = nil
  }

  private func consume(_ pointer: UnsafeMutablePointer<FeatherAiResult>)
    -> FeatherGenerationResultValue
  {
    defer { feather_ai_result_free(pointer) }
    let result = pointer.pointee
    let candidates: [FeatherGeneratedCandidateValue]
    if let base = result.candidates, result.candidate_count > 0 {
      candidates = UnsafeBufferPointer(start: base, count: result.candidate_count).map {
        FeatherGeneratedCandidateValue(
          text: $0.text.map(String.init(cString:)) ?? "",
          score: $0.score
        )
      }
    } else {
      candidates = []
    }
    return FeatherGenerationResultValue(
      requestID: result.request_id,
      revision: result.revision,
      candidates: candidates,
      elapsedMilliseconds: result.elapsed_ms,
      truncated: result.truncated != 0
    )
  }
}

@MainActor
final class FeatherScoringRequest: FeatherScoringRequesting {
  private var handle: OpaquePointer?

  fileprivate init(handle: OpaquePointer) {
    self.handle = handle
  }

  deinit {
    feather_ai_scoring_request_free(handle)
  }

  func poll(currentRequestID: UInt64, currentRevision: UInt64) throws
    -> FeatherScoringState
  {
    guard let handle else { return .cancelled }
    var rawState = FEATHER_AI_REQUEST_PENDING.rawValue
    var result: UnsafeMutablePointer<FeatherAiScoringResult>?
    var ffiError: UnsafeMutablePointer<FeatherError>?
    let status = feather_ai_scoring_request_poll(
      handle,
      currentRequestID,
      currentRevision,
      &rawState,
      &result,
      &ffiError
    )
    do {
      try FeatherSession.check(status: status, error: ffiError, operation: "poll MLX scoring")
    } catch {
      feather_ai_scoring_result_free(result)
      throw error
    }

    switch rawState {
    case FEATHER_AI_REQUEST_PENDING.rawValue:
      guard result == nil else {
        feather_ai_scoring_result_free(result)
        throw FeatherBridgeError.invalidSuccess(operation: "pending MLX scoring")
      }
      return .pending
    case FEATHER_AI_REQUEST_READY.rawValue:
      guard let result else {
        throw FeatherBridgeError.invalidSuccess(operation: "ready MLX scoring")
      }
      return .ready(consume(result))
    case FEATHER_AI_REQUEST_FAILED.rawValue:
      feather_ai_scoring_result_free(result)
      return .failed
    case FEATHER_AI_REQUEST_CANCELLED.rawValue:
      feather_ai_scoring_result_free(result)
      return .cancelled
    case FEATHER_AI_REQUEST_STALE.rawValue:
      feather_ai_scoring_result_free(result)
      return .stale
    default:
      feather_ai_scoring_result_free(result)
      throw FeatherBridgeError.invalidSuccess(operation: "unknown MLX scoring state \(rawState)")
    }
  }

  func cancel() throws {
    guard let handle else { return }
    var ffiError: UnsafeMutablePointer<FeatherError>?
    let status = feather_ai_scoring_request_cancel(handle, &ffiError)
    try FeatherSession.check(status: status, error: ffiError, operation: "cancel MLX scoring")
  }

  func close() {
    guard let handle else { return }
    feather_ai_scoring_request_free(handle)
    self.handle = nil
  }

  private func consume(_ pointer: UnsafeMutablePointer<FeatherAiScoringResult>)
    -> FeatherScoringResultValue
  {
    defer { feather_ai_scoring_result_free(pointer) }
    let result = pointer.pointee
    let candidates: [FeatherScoredCandidateValue]
    if let base = result.candidates, result.candidate_count > 0 {
      candidates = UnsafeBufferPointer(start: base, count: result.candidate_count).map {
        FeatherScoredCandidateValue(
          value: $0.value,
          text: $0.text.map(String.init(cString:)) ?? "",
          modelScore: $0.lm_score,
          score: $0.score
        )
      }
    } else {
      candidates = []
    }
    return FeatherScoringResultValue(
      requestID: result.request_id,
      revision: result.revision,
      candidates: candidates,
      elapsedMilliseconds: result.elapsed_ms
    )
  }
}
