import Foundation

/// Shared-secret auth between the hook scripts and the local HTTP server.
///
/// Without it, any local process — or a webpage doing a cross-origin
/// `text/plain` POST to 127.0.0.1 (no CORS preflight needed) — could spoof
/// overlay notifications, including fake permission prompts. The token lives
/// in a 0600 file only the user can read; hooks send it back as a header.
enum AuthToken {
    static let header = "x-boopr-token"

    static var configDir: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("boopr")
    }

    static var tokenFile: URL { configDir.appendingPathComponent("token") }

    /// Returns the persisted token, generating it on first launch.
    /// Returns nil only if the config dir is unwritable — the server then runs
    /// without auth (matching pre-token behavior) rather than rejecting everything.
    static func load() -> String? {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: tokenFile) {
            let tok = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !tok.isEmpty { return tok }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            NSLog("AuthToken: SecRandomCopyBytes failed")
            return nil
        }
        let tok = bytes.map { String(format: "%02x", $0) }.joined()
        do {
            try fm.createDirectory(at: configDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try Data(tok.utf8).write(to: tokenFile, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
            NSLog("AuthToken: generated new token at \(tokenFile.path)")
            return tok
        } catch {
            NSLog("AuthToken: could not persist token: \(error)")
            return nil
        }
    }
}
