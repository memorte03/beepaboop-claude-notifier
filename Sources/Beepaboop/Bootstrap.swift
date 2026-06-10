import Foundation

/// First-launch setup so the app works when simply dragged to /Applications and
/// opened — no install script. Copies the bundled hook scripts into the config
/// dir and wires them into ~/.claude/settings.json. Idempotent and safe to
/// re-run; the settings.json wiring happens only once (or on explicit repair) so
/// it never fights a user who deliberately removed the hooks.
enum Bootstrap {
    /// Bump when the bundled hook scripts change so installed copies refresh.
    static let hooksVersion = 1

    private static var hooksDir: URL { AuthToken.configDir.appendingPathComponent("hooks") }
    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }
    private static var bundledHooks: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("hooks")
    }

    /// Default PreToolUse matcher — the tools that get an Approve/Deny overlay.
    static let defaultMatcher = "Bash|Write|Edit|MultiEdit|NotebookEdit"

    /// Runs on launch (off the main thread). Refreshes hook files when the
    /// bundle is newer, and wires settings.json the first time only.
    static func runIfNeeded() {
        DispatchQueue.global(qos: .utility).async {
            let installed = UserDefaults.standard.integer(forKey: "hooksVersion")
            // Forward-only refresh: don't overwrite newer installed hooks if a
            // downgraded build (lower hooksVersion) ever runs.
            if installed < hooksVersion || !FileManager.default.fileExists(atPath: hooksDir.path) {
                if copyHooks() {
                    UserDefaults.standard.set(hooksVersion, forKey: "hooksVersion")
                }
            }
            if !UserDefaults.standard.bool(forKey: "settingsWired") {
                if wireSettings() {
                    UserDefaults.standard.set(true, forKey: "settingsWired")
                }
            }
        }
    }

    /// Forced reinstall (menu → Reinstall hooks): refresh files and re-wire.
    @discardableResult
    static func repair() -> Bool {
        let ok = copyHooks() && wireSettings()
        if ok {
            UserDefaults.standard.set(hooksVersion, forKey: "hooksVersion")
            UserDefaults.standard.set(true, forKey: "settingsWired")
        }
        return ok
    }

    /// Whether jq — required by the hooks at runtime — is reachable.
    static func jqAvailable() -> Bool {
        let candidates = ["/opt/homebrew/bin/jq", "/usr/local/bin/jq", "/usr/bin/jq"]
        if candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return true
        }
        // Fall back to a PATH lookup via the login shell.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["sh", "-lc", "command -v jq"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run(); p.waitUntilExit()
            return p.terminationStatus == 0
        } catch { return false }
    }

    // MARK: - private

    @discardableResult
    private static func copyHooks() -> Bool {
        guard let src = bundledHooks,
              FileManager.default.fileExists(atPath: src.path) else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            for name in ["beepaboop-common.sh", "notify.sh", "permission.sh"] {
                let from = src.appendingPathComponent(name)
                let to = hooksDir.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else { continue }
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: to.path)
            }
            return true
        } catch {
            NSLog("Bootstrap: copyHooks failed: \(error)")
            return false
        }
    }

    /// Merges our hook entries into ~/.claude/settings.json, dropping any prior
    /// beepaboop entries first (so repeated runs converge). Pure
    /// Foundation — no jq needed for setup.
    @discardableResult
    private static func wireSettings() -> Bool {
        let fm = FileManager.default
        let notify = hooksDir.appendingPathComponent("notify.sh").path
        let permission = hooksDir.appendingPathComponent("permission.sh").path

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            // The file exists but doesn't parse: abort rather than treating it as
            // empty and overwriting (which would wipe every other setting).
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("Bootstrap: settings.json exists but isn't valid JSON — skipping wire to avoid data loss")
                return false
            }
            root = obj
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        func ours(_ matcher: String, _ command: String) -> [String: Any] {
            ["matcher": matcher, "hooks": [["type": "command", "command": command]]]
        }
        func dropOurs(_ value: Any?) -> [[String: Any]] {
            let list = value as? [[String: Any]] ?? []
            return list.filter { entry in
                let inner = entry["hooks"] as? [[String: Any]] ?? []
                return !inner.contains { ($0["command"] as? String ?? "").contains("beepaboop") }
            }
        }

        hooks["Stop"]         = dropOurs(hooks["Stop"])         + [ours("", notify)]
        hooks["Notification"] = dropOurs(hooks["Notification"]) + [ours("", notify)]
        hooks["PreToolUse"]   = dropOurs(hooks["PreToolUse"])   + [ours(defaultMatcher, permission)]
        root["hooks"] = hooks

        do {
            try fm.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            // Back up the original once and never clobber it, so a re-run
            // (e.g. menu → Reinstall hooks) can't lose the user's true original.
            let bak = settingsURL.appendingPathExtension("bak")
            if fm.fileExists(atPath: settingsURL.path), !fm.fileExists(atPath: bak.path) {
                try? fm.copyItem(at: settingsURL, to: bak)
            }
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: settingsURL, options: .atomic)
            return true
        } catch {
            NSLog("Bootstrap: wireSettings failed: \(error)")
            return false
        }
    }
}
