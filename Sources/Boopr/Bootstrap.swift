import Foundation

/// First-launch setup so the app works when simply dragged to /Applications and
/// opened — no install script. Copies the bundled hook scripts into the config
/// dir and wires them into ~/.claude/settings.json. Idempotent and safe to
/// re-run; the settings.json wiring happens only once (or on explicit repair) so
/// it never fights a user who deliberately removed the hooks.
enum Bootstrap {
    /// Bump when the bundled hook scripts change so installed copies refresh.
    /// v2: thin wrappers that exec `Boopr __hook …` (no jq, no boopr-common.sh).
    static let hooksVersion = 2

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
            // The wrapper scripts resolve the binary through this file, so it
            // survives the app being moved or renamed. Refresh it every launch.
            writeBinPath()
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

    /// Records this binary's path so the wrapper scripts can find it after a
    /// move/rename. Written next to the auth token; best-effort.
    static func writeBinPath() {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path else { return }
        let fm = FileManager.default
        let binFile = AuthToken.configDir.appendingPathComponent("bin")
        try? fm.createDirectory(at: AuthToken.configDir, withIntermediateDirectories: true)
        try? Data(exe.utf8).write(to: binFile, options: .atomic)
    }

    // MARK: - private

    @discardableResult
    private static func copyHooks() -> Bool {
        guard let src = bundledHooks,
              FileManager.default.fileExists(atPath: src.path) else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            for name in ["notify.sh", "permission.sh"] {
                let from = src.appendingPathComponent(name)
                let to = hooksDir.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else { continue }
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: to.path)
            }
            // Tidy up the pre-v2 shared library; the wrappers no longer source it.
            try? fm.removeItem(at: hooksDir.appendingPathComponent("boopr-common.sh"))
            return true
        } catch {
            NSLog("Bootstrap: copyHooks failed: \(error)")
            return false
        }
    }

    /// Merges our hook entries into ~/.claude/settings.json, dropping any prior
    /// boopr entries first (so repeated runs converge). Pure
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
                return !inner.contains { ($0["command"] as? String ?? "").contains("boopr") }
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

    /// Strips boopr's hook entries from ~/.claude/settings.json (preserving any
    /// other hooks). Used by `Boopr __unwire`, called from uninstall.sh so the
    /// teardown needs no jq. Other settings are untouched.
    @discardableResult
    static func unwireSettings() -> Bool {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: settingsURL),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        guard var hooks = root["hooks"] as? [String: Any] else { return true }

        func dropOurs(_ value: Any?) -> [[String: Any]] {
            let list = value as? [[String: Any]] ?? []
            return list.filter { entry in
                let inner = entry["hooks"] as? [[String: Any]] ?? []
                return !inner.contains { ($0["command"] as? String ?? "").contains("boopr") }
            }
        }

        for event in ["Stop", "Notification", "PreToolUse"] {
            let remaining = dropOurs(hooks[event])
            if remaining.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = remaining }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") }
        else { root["hooks"] = hooks }

        do {
            let bak = settingsURL.appendingPathExtension("bak")
            try? fm.copyItem(at: settingsURL, to: bak)
            let out = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try out.write(to: settingsURL, options: .atomic)
            return true
        } catch {
            NSLog("Bootstrap: unwireSettings failed: \(error)")
            return false
        }
    }
}
