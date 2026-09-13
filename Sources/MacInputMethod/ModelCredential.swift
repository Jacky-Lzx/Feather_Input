import Foundation

/// Plaintext local configuration, explicitly requested instead of Keychain access.
enum ModelCredential {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FeatherInput/lm-studio-token.txt")

    static func read() -> String {
        // Read the small local file afresh so manual edits take effect on the next request.
        guard let data = try? Data(contentsOf: fileURL), data.count <= 8192,
              let token = String(data: data, encoding: .utf8) else { return "" }
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func save(_ token: String) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.utf8.count <= 8192, !token.contains("\n"), !token.contains("\r") else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try Data(token.utf8).write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
