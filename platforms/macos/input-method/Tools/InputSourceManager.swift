import Carbon
import Foundation

private enum ManagerError: LocalizedError {
  case invalidArguments
  case registrationFailed(OSStatus)
  case enableFailed(identifier: String, status: OSStatus)
  case disableFailed(identifier: String, status: OSStatus)
  case queryUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      return
        "用法：input-source-manager register <bundle-path> | status <bundle-id> | enable <bundle-id> | disable <bundle-id>"
    case .registrationFailed(let status):
      return "注册输入源失败：OSStatus=\(status)"
    case .enableFailed(let identifier, let status):
      return "启用输入源失败（\(identifier)）：OSStatus=\(status)"
    case .disableFailed(let identifier, let status):
      return "禁用输入源失败（\(identifier)）：OSStatus=\(status)"
    case .queryUnavailable:
      return "无法连接当前图形登录会话的 Text Input Sources 服务。"
    }
  }
}

private struct SourceDescription {
  let identifier: String
  let enabled: Bool
  let enableCapable: Bool
  let selectable: Bool
}

@main
private enum InputSourceManager {
  static func main() {
    do {
      try run()
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  private static func run() throws {
    guard CommandLine.arguments.count == 3 else { throw ManagerError.invalidArguments }
    let command = CommandLine.arguments[1]
    let argument = CommandLine.arguments[2]
    switch command {
    case "register":
      let url = URL(fileURLWithPath: argument, isDirectory: true) as CFURL
      let status = TISRegisterInputSource(url)
      guard status == noErr else { throw ManagerError.registrationFailed(status) }
      print("已向 Text Input Sources 注册：\(argument)")
    case "status":
      let sources = try sources(bundleIdentifier: argument)
      if sources.isEmpty {
        print("未发现 Bundle ID 为 \(argument) 的输入源。")
      } else {
        for source in sources {
          print(
            "\(source.identifier)\tenabled=\(source.enabled)\tenableCapable=\(source.enableCapable)\tselectable=\(source.selectable)"
          )
        }
      }
    case "enable":
      for (source, description) in try sourcePairs(bundleIdentifier: argument)
      where description.enableCapable && !description.enabled {
        let status = TISEnableInputSource(source)
        guard status == noErr else {
          throw ManagerError.enableFailed(identifier: description.identifier, status: status)
        }
        print("已启用输入源：\(description.identifier)")
      }
    case "disable":
      for (source, description) in try sourcePairs(bundleIdentifier: argument).reversed()
      where description.enabled {
        let status = TISDisableInputSource(source)
        guard status == noErr else {
          throw ManagerError.disableFailed(identifier: description.identifier, status: status)
        }
        print("已禁用输入源：\(description.identifier)")
      }
    default:
      throw ManagerError.invalidArguments
    }
  }

  private static func sources(bundleIdentifier: String) throws -> [SourceDescription] {
    try sourcePairs(bundleIdentifier: bundleIdentifier).map(\.1)
  }

  private static func sourcePairs(
    bundleIdentifier: String
  ) throws -> [(TISInputSource, SourceDescription)] {
    let filter = [kTISPropertyBundleID as String: bundleIdentifier] as CFDictionary
    guard let result = TISCreateInputSourceList(filter, true) else {
      throw ManagerError.queryUnavailable
    }
    let values = result.takeRetainedValue() as NSArray
    return values.map { value in
      let source = value as! TISInputSource
      let identifier = stringProperty(source, key: kTISPropertyInputSourceID) ?? "<unknown>"
      return (
        source,
        SourceDescription(
          identifier: identifier,
          enabled: boolProperty(source, key: kTISPropertyInputSourceIsEnabled),
          enableCapable: boolProperty(source, key: kTISPropertyInputSourceIsEnableCapable),
          selectable: boolProperty(source, key: kTISPropertyInputSourceIsSelectCapable)
        )
      )
    }
  }

  private static func stringProperty(_ source: TISInputSource, key: CFString) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
  }

  private static func boolProperty(_ source: TISInputSource, key: CFString) -> Bool {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
    return Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue() == kCFBooleanTrue
  }
}
