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

enum FeatherBridgeError: LocalizedError {
  case unsupportedABI(UInt32)
  case sessionCreationFailed
  case dispatchFailed(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedABI(let version):
      return "不支持 Feather C ABI 版本：\(version)"
    case .sessionCreationFailed:
      return "无法创建 librime 会话。请检查共享数据、用户数据和 schema。"
    case .dispatchFailed(let operation):
      return "Feather C ABI 调用失败：\(operation)"
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
  private var handle: OpaquePointer?

  init(sharedData: URL, userData: URL, schema: String) throws {
    let version = feather_ime_abi_version()
    guard version == 1 else {
      throw FeatherBridgeError.unsupportedABI(version)
    }

    handle = sharedData.path.withCString { sharedPath in
      userData.path.withCString { userPath in
        schema.withCString { schemaName in
          feather_ime_new_rime(sharedPath, userPath, schemaName)
        }
      }
    }
    guard handle != nil else {
      throw FeatherBridgeError.sessionCreationFailed
    }
  }

  deinit {
    if let handle {
      feather_ime_free(handle)
    }
  }

  func activate() throws -> FeatherResponseValue {
    try consume(feather_ime_activate(requireHandle()), operation: "activate")
  }

  func deactivate() throws -> FeatherResponseValue {
    try consume(feather_ime_deactivate(requireHandle()), operation: "deactivate")
  }

  func send(_ key: FeatherKey) throws -> FeatherResponseValue {
    try consume(
      feather_ime_key(requireHandle(), key.rawValue, nil, 0),
      operation: "key \(key)"
    )
  }

  func send(text: String) throws -> FeatherResponseValue {
    let bytes = Array(text.utf8)
    let response = bytes.withUnsafeBufferPointer { buffer in
      feather_ime_key(
        requireHandle(),
        FeatherKey.text.rawValue,
        buffer.baseAddress,
        buffer.count
      )
    }
    return try consume(response, operation: "text")
  }

  func select(_ candidate: FeatherCandidateValue) throws -> FeatherResponseValue {
    try consume(
      feather_ime_select_candidate(requireHandle(), candidate.revision, candidate.value),
      operation: "select candidate"
    )
  }

  private func requireHandle() -> OpaquePointer {
    precondition(handle != nil, "Feather session 已经释放")
    return handle!
  }

  private func consume(
    _ pointer: UnsafeMutablePointer<FeatherResponse>?,
    operation: String
  ) throws -> FeatherResponseValue {
    guard let pointer else {
      throw FeatherBridgeError.dispatchFailed(operation)
    }
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
