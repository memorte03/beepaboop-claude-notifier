import Foundation

/// In-process port of `permission.sh`'s allow/deny short-circuit. Reads
/// ~/.claude/settings.local.json then settings.json and matches the tool against
/// `permissions.allow` / `permissions.deny`, with the same matching semantics
/// the bash used (bare name, `Tool(*)`, prefix `:*`, trailing `/*`).
enum PermissionRules {
    /// True if `tool` (with its tool_input) is matched by any rule in `list`
    /// ("allow" | "deny") across the user's settings files.
    static func matches(tool: String, list: String, input: HookInput) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let files = [
            home.appendingPathComponent(".claude/settings.local.json"),
            home.appendingPathComponent(".claude/settings.json"),
        ]
        for file in files {
            for rule in rules(in: file, list: list) where !rule.isEmpty {
                if ruleMatches(tool: tool, rule: rule, input: input) { return true }
            }
        }
        return false
    }

    private static func rules(in file: URL, list: String) -> [String] {
        guard let data = try? Data(contentsOf: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let perms = root["permissions"] as? [String: Any],
              let arr = perms[list] as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }
    }

    private static func ruleMatches(tool: String, rule: String, input: HookInput) -> Bool {
        // Bare tool-name match (e.g. "WebFetch", "mcp__foo__bar").
        if rule == tool { return true }

        // Tool(pattern) form. Match the literal "tool(" prefix and ")" suffix.
        let prefix = "\(tool)("
        guard rule.hasPrefix(prefix), rule.hasSuffix(")") else { return false }
        let pattern = String(rule.dropFirst(prefix.count).dropLast())

        switch tool {
        case "Bash":
            let cmd = input.ti("command")
            if pattern == "*" || pattern == ":*" { return true }
            if pattern.hasSuffix(":*") {
                let p = String(pattern.dropLast(2))
                if !p.isEmpty, cmd.hasPrefix(p) { return true }
            }
            return pattern == cmd
        case "Write", "Edit", "MultiEdit", "NotebookEdit", "Read", "Update":
            if pattern == "*" || pattern == "*:*" { return true }
            let path = input.tiAny("file_path", "path", "notebook_path")
            if pattern == path { return true }
            if pattern.hasSuffix("/*") {
                let base = String(pattern.dropLast(2))
                return path.hasPrefix(base + "/")
            }
            return false
        default:
            return pattern == "*" || pattern == "*:*"
        }
    }
}
