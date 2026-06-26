import Foundation

/// The `Boopr __hook {notify|permission}` command. Claude Code runs the thin
/// wrapper scripts, which `exec` this — so all the hook logic (JSON, terminal
/// detection, HTTP) lives here in Foundation, and the shipped app needs no `jq`.
///
/// Contract with Claude Code:
///   - notify     → fire-and-forget POST /notify, always exit 0.
///   - permission → blocking POST /permission, print the permissionDecision
///                  JSON. Any failure falls back to "ask" so Claude's native
///                  prompt takes over.
enum HookCLI {
    private static var port: UInt16 {
        ProcessInfo.processInfo.environment["BOOPR_PORT"].flatMap(UInt16.init) ?? 7891
    }

    /// Read-only token load — never generates one (that's the app's job).
    private static var token: String? {
        guard let data = try? Data(contentsOf: AuthToken.tokenFile) else { return nil }
        let tok = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return tok.isEmpty ? nil : tok
    }

    static func run(_ args: [String]) -> Never {
        let mode = args.first ?? ""
        let raw = FileHandle.standardInput.readDataToEndOfFile()
        let input = HookInput(raw)
        switch mode {
        case "notify":     runNotify(input)
        case "permission": runPermission(input)
        default:           exit(0)
        }
    }

    // MARK: - notify (Stop / Notification)

    private static func runNotify(_ input: HookInput) -> Never {
        let kind: NotifyKind
        let title: String
        switch input.event {
        case "Stop", "SubagentStop":
            kind = .stop; title = "Claude is done"
        case "Notification":
            kind = .idle; title = "Claude is waiting for you"
        default:
            kind = .info; title = "Claude: \(input.event)"
        }
        let context = HookContext.trim(input.message)
        let req = HookContext.buildPayload(input: input, id: HookContext.uuid(),
                                           kind: kind, title: title, context: context)
        if let body = try? JSONEncoder().encode(req) {
            _ = post(path: "/notify", body: body, timeout: 2)
        }
        exit(0)
    }

    // MARK: - permission (PreToolUse, blocking)

    private static func runPermission(_ input: HookInput) -> Never {
        let tool = input.toolName

        // Deny rules win: defer to Claude's own evaluation (which honors deny).
        if PermissionRules.matches(tool: tool, list: "deny", input: input) {
            emitDecision("ask"); exit(0)
        }
        // Pre-approved by an allow rule → skip the overlay entirely.
        if PermissionRules.matches(tool: tool, list: "allow", input: input) {
            emitDecision("allow"); exit(0)
        }

        var title = "Run \(tool)?"
        var context = ""
        var diff = ""

        switch tool {
        case "Bash":
            context = HookContext.trim("$ " + input.ti("command"))
            title = "Run shell command?"
        case "Edit":
            let path = input.tiAny("file_path", "path")
            diff = HookContext.diffPreview(old: input.ti("old_string"), new: input.ti("new_string"))
            context = HookContext.trim(path)
            title = "Modify \(HookContext.basename(path))?"
        case "MultiEdit":
            let path = input.ti("file_path")
            let edits = input.toolInput["edits"] as? [[String: Any]] ?? []
            let first = edits.first ?? [:]
            diff = HookContext.diffPreview(old: first["old_string"] as? String ?? "",
                                           new: first["new_string"] as? String ?? "")
            context = "\(path) (\(edits.count) edits)"
            title = "Apply \(edits.count) edits to \(HookContext.basename(path))?"
        case "Write":
            let path = input.ti("file_path")
            let oldContent = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            diff = HookContext.diffPreview(old: oldContent, new: input.ti("content"))
            if FileManager.default.fileExists(atPath: path) {
                context = "overwrite \(path)"; title = "Overwrite \(HookContext.basename(path))?"
            } else {
                context = "create \(path)"; title = "Create \(HookContext.basename(path))?"
            }
        case "NotebookEdit":
            context = HookContext.trim(input.ti("notebook_path"))
            title = "Edit notebook?"
        case "WebFetch", "WebSearch":
            context = HookContext.trim(input.tiAny("url", "query"))
            title = "Run \(tool)?"
        default:
            context = HookContext.trim(input.toolInputString)
            title = "Run \(tool)?"
        }

        let req = HookContext.buildPayload(input: input, id: HookContext.uuid(),
                                           kind: .permission, title: title, context: context,
                                           actions: ["Approve", "Deny"], diff: diff)
        guard let body = try? JSONEncoder().encode(req) else { emitDecision("ask"); exit(0) }

        let response = post(path: "/permission", body: body, timeout: 15)
        var decision = "ask"
        var reason: String? = nil
        if let response,
           let parsed = try? JSONDecoder().decode(PermissionResponse.self, from: response) {
            if ["allow", "deny", "ask"].contains(parsed.decision) { decision = parsed.decision }
            reason = parsed.reason
        }
        emitDecision(decision, reason: reason)
        exit(0)
    }

    // MARK: - PreToolUse decision output

    private struct PreToolUseOutput: Encodable {
        struct Inner: Encodable {
            let hookEventName = "PreToolUse"
            let permissionDecision: String
            let permissionDecisionReason: String?
        }
        let hookSpecificOutput: Inner
    }

    private static func emitDecision(_ decision: String, reason: String? = nil) {
        let out = PreToolUseOutput(hookSpecificOutput:
            .init(permissionDecision: decision, permissionDecisionReason: reason))
        guard let data = try? JSONEncoder().encode(out) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    // MARK: - HTTP

    /// Synchronous POST to the local server. Returns the response body, or nil on
    /// any failure (e.g. the app isn't running → connection refused → caller
    /// falls back). A refused connection returns near-instantly.
    private static func post(path: String, body: Data, timeout: TimeInterval) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue(token, forHTTPHeaderField: AuthToken.header) }
        req.httpBody = body

        // Box the result so it can cross the @Sendable completion closure.
        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: req) { data, _, _ in
            box.data = data
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 1)
        return box.data
    }
}
