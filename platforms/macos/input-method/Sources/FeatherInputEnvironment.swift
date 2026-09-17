import Foundation

@MainActor
enum FeatherInputEnvironment {
  static let schema = "luna_pinyin_simp"
  static var sharedDataOverride: URL?
  static var userDataOverride: URL?

  static func sharedData() throws -> URL {
    if let sharedDataOverride { return sharedDataOverride }
    guard let resources = Bundle.main.resourceURL else {
      throw FeatherBridgeError.sessionCreationFailed
    }
    return resources.appendingPathComponent("rime", isDirectory: true)
  }

  static func userData() throws -> URL {
    if let userDataOverride { return userDataOverride }
    guard
      let directory = Bundle.main.object(forInfoDictionaryKey: "FeatherUserDataDirectory")
        as? String,
      !directory.isEmpty,
      !directory.contains("/")
    else {
      throw FeatherBridgeError.sessionCreationFailed
    }
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return
      applicationSupport
      .appendingPathComponent(directory, isDirectory: true)
      .appendingPathComponent("Rime", isDirectory: true)
  }
}
