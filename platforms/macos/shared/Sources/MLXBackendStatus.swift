import FeatherIME
import Foundation

enum MLXBackendStatus: Equatable {
  case checking
  case ready
  case unavailable
  case incompatible

  var displayText: String {
    switch self {
    case .checking:
      return "MLX 后端：正在检查…"
    case .ready:
      return "MLX 后端：可用（127.0.0.1:1235）"
    case .unavailable:
      return "MLX 后端：未运行或未就绪"
    case .incompatible:
      return "MLX 后端：响应不兼容"
    }
  }
}

enum FeatherMLXBackendStatusProbe {
  static func check() -> MLXBackendStatus {
    var rawStatus: UInt32 = 0
    var ffiError: UnsafeMutablePointer<FeatherError>?
    let status = feather_ai_mlx_backend_status(&rawStatus, &ffiError)
    defer { feather_error_free(ffiError) }
    guard status == FEATHER_STATUS_OK.rawValue else { return .unavailable }
    switch rawStatus {
    case FEATHER_MLX_BACKEND_READY.rawValue:
      return .ready
    case FEATHER_MLX_BACKEND_INCOMPATIBLE.rawValue:
      return .incompatible
    default:
      return .unavailable
    }
  }
}
