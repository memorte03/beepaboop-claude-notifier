import AppKit
import ApplicationServices
import Foundation

/// Focuses the exact tmux pane a Claude session runs in, plus the terminal
/// window displaying it. tmux is the source of truth — the hook captures the
/// pane id, socket and binary path — so this works no matter how many
/// terminal windows are open or what their titles say.
///
/// Strategy on jump:
///   1. `select-window` + `select-pane` make the pane active inside its
///      session (works always, no permissions).
///   2. `list-clients` maps the session to the tty of the terminal window
///      attached to it; if no client shows the session, the most recently
///      active client is switched to it.
///   3. The macOS window for that tty is identified by writing a unique
///      title marker (OSC 2) directly to the tty device — this bypasses tmux
///      and instantly renames exactly one window — then the AX window carrying
///      the marker is raised and the original title is restored.
///
/// Step 3 needs Accessibility; steps 1–2 need nothing. Without AX we still
/// select the pane and activate the app, which already beats title guessing.
enum TmuxFocuser {

    struct Target: Sendable {
        let bin: String
        let socket: String
        let pane: String
    }

    static func target(from req: NotifyRequest) -> Target? {
        guard let bin = req.tmuxBin, !bin.isEmpty,
              let socket = req.tmuxSocket, !socket.isEmpty,
              let pane = req.tmuxPane, !pane.isEmpty
        else { return nil }
        return Target(bin: bin, socket: socket, pane: pane)
    }

    /// Returns false when the request carries no usable tmux identity or the
    /// pane no longer exists (e.g. tmux server restarted) — the caller should
    /// fall back to the app/title-based path.
    static func focus(req: NotifyRequest) -> Bool {
        guard let t = target(from: req), let session = paneSession(t) else { return false }

        // Pane-level focus. `-t <pane>` on select-window resolves to the
        // window containing the pane.
        tmux(t, "select-window", "-t", t.pane)
        tmux(t, "select-pane", "-t", t.pane)

        let terminalPid: pid_t? = {
            if let pid = req.terminalPid { return pid_t(pid) }
            if let bid = req.terminalApp {
                return NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                    .first?.processIdentifier
            }
            return nil
        }()

        // Window-level focus happens off-main: it shells out to tmux and
        // polls AX with short sleeps.
        let bundleID = req.terminalApp
        DispatchQueue.global(qos: .userInitiated).async {
            guard let tty = clientTty(t, session: session) else {
                NSLog("TmuxFocuser: no client tty for session \(session) — activating app")
                activateApp(pid: terminalPid)
                return
            }
            // Ghostty ≥1.3 has AppleScript: unlike the AX window list, it sees
            // terminals on every Space, and `focus` raises the right window
            // natively. Identification still uses the title marker (the tty
            // property only lands in 1.4).
            if bundleID == "com.mitchellh.ghostty", ghosttyRaise(clientTty: tty) {
                return
            }
            guard let pid = terminalPid else {
                NSLog("TmuxFocuser: no terminal pid/bundle — cannot raise window")
                return
            }
            guard AXIsProcessTrusted() else {
                NSLog("TmuxFocuser: Accessibility not granted — activating app only")
                activateApp(pid: pid)
                return
            }
            raiseWindow(appPid: pid, clientTty: tty)
        }
        return true
    }

    /// Sends literal keys (e.g. ["1", "Enter"]) straight to the captured
    /// pane — no focus, no Accessibility, no window switching.
    /// Returns false if the pane is gone so the caller can fall back.
    static func sendKeys(_ keys: [String], to req: NotifyRequest) -> Bool {
        guard let t = target(from: req), paneSession(t) != nil else { return false }
        return tmux(t, ["send-keys", "-t", t.pane] + keys) != nil
    }

    /// Deterministic "is the user already looking at this pane" check:
    /// the pane must be the active pane of the active window of its session,
    /// and a client attached to that session must report OS focus (tmux tracks
    /// terminal focus-in/out per client). Returns nil when the request has no
    /// tmux identity or the pane is gone — caller falls back to heuristics.
    static func isPaneFocused(req: NotifyRequest) -> Bool? {
        guard let t = target(from: req) else { return nil }
        guard let active = tmux(t, "display-message", "-p", "-t", t.pane,
                                "#{?#{&&:#{pane_active},#{window_active}},1,0}"),
              let session = paneSession(t)
        else { return nil }
        if active != "1" { return false }

        guard let out = tmux(t, "list-clients", "-F",
                             "#{client_session}\u{1F}#{client_flags}") else { return false }
        for line in out.split(separator: "\n") {
            let parts = line.components(separatedBy: "\u{1F}")
            if parts.count >= 2, parts[0] == session, parts[1].contains("focused") {
                return true
            }
        }
        return false
    }

    // MARK: - tmux plumbing

    /// Session currently containing the pane (nil ⇒ pane is gone).
    private static func paneSession(_ t: Target) -> String? {
        guard let out = tmux(t, "display-message", "-p", "-t", t.pane, "#{session_name}"),
              !out.isEmpty else { return nil }
        return out
    }

    /// tty of the client displaying `session`. If none, retargets the most
    /// recently active client to the session and returns its tty.
    private static func clientTty(_ t: Target, session: String) -> String? {
        guard let out = tmux(t, "list-clients", "-F",
                             "#{client_tty}\u{1F}#{client_session}\u{1F}#{client_activity}")
        else { return nil }
        var newest: (tty: String, activity: Int)?
        for line in out.split(separator: "\n") {
            let parts = line.components(separatedBy: "\u{1F}")
            guard parts.count >= 3 else { continue }
            if parts[1] == session { return parts[0] }
            let activity = Int(parts[2]) ?? 0
            if newest == nil || activity > newest!.activity {
                newest = (parts[0], activity)
            }
        }
        guard let newest else { return nil }
        // Side effect: no client is showing this session, so we retarget the
        // most-recently-active client onto it — that terminal window is moved
        // off whatever session it was displaying. Expected for "jump", but note
        // it changes what isPaneFocused/the watcher observe for that client.
        guard tmux(t, "switch-client", "-c", newest.tty, "-t", session) != nil else { return nil }
        return newest.tty
    }

    @discardableResult
    private static func tmux(_ t: Target, _ args: String...) -> String? {
        tmux(t, args)
    }

    @discardableResult
    private static func tmux(_ t: Target, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: t.bin)
        p.arguments = ["-S", t.socket] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            NSLog("TmuxFocuser: failed to run tmux: \(error)")
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - window raising (Ghostty AppleScript)

    /// Identify the Ghostty terminal showing `clientTty` by writing a title
    /// marker to the tty, then find + focus it via the scripting interface
    /// introduced in Ghostty 1.3 and restore the original title. Returns
    /// false on older Ghostty or denied Automation permission — callers fall
    /// back to the AX path.
    private static func ghosttyRaise(clientTty: String) -> Bool {
        let before = ghosttyTerminals()
        guard !before.isEmpty else { return false }

        let nonce = "cn-focus-\(UUID().uuidString.prefix(8))"
        guard writeTitle(nonce, toTty: clientTty) else { return false }

        var focusedID: String?
        for _ in 0..<8 {
            usleep(60_000)
            if let id = ghosttyFocusMarked(nonce) { focusedID = id; break }
        }

        guard let id = focusedID else {
            // Marker stuck on a title we couldn't find (terminal busy?) —
            // overwrite with something sane since we can't know the original.
            _ = writeTitle("tmux", toTty: clientTty)
            NSLog("TmuxFocuser: Ghostty AppleScript marker \(nonce) not found")
            return false
        }
        if let original = before.first(where: { $0.id == id })?.name {
            _ = writeTitle(original, toTty: clientTty)
        }
        NSLog("TmuxFocuser: Ghostty AppleScript focused terminal \(id) (tty \(clientTty))")
        return true
    }

    /// (id, title) of every Ghostty terminal, across all windows and Spaces.
    /// Empty on pre-1.3 Ghostty or when Automation permission is denied.
    private static func ghosttyTerminals() -> [(id: String, name: String)] {
        let script = """
        tell application id "com.mitchellh.ghostty"
            set out to ""
            repeat with i from 1 to (count of terminals)
                set t to terminal i
                set out to out & (get id of t) & "\u{1F}" & (get name of t) & linefeed
            end repeat
            return out
        end tell
        """
        guard let out = runAppleScript(script) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\u{1F}")
            guard parts.count >= 2 else { return nil }
            return (parts[0], parts[1])
        }
    }

    /// Focus the Ghostty terminal whose title contains `marker`; returns its
    /// stable id, or nil when nothing matches (yet).
    private static func ghosttyFocusMarked(_ marker: String) -> String? {
        let script = """
        tell application id "com.mitchellh.ghostty"
            repeat with i from 1 to (count of terminals)
                set t to terminal i
                if (get name of t) contains "\(marker)" then
                    focus t
                    activate
                    return get id of t
                end if
            end repeat
        end tell
        return ""
        """
        guard let out = runAppleScript(script), !out.isEmpty else { return nil }
        return out
    }

    private static func runAppleScript(_ source: String) -> String? {
        // NSAppleScript is main-thread only. Callers are always off-main (the
        // raise/focus work runs on a utility queue); guard anyway so a future
        // main-thread caller runs inline instead of dead-locking on main.sync.
        func run() -> String? {
            var error: NSDictionary?
            let out = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { NSLog("TmuxFocuser: AppleScript error: \(error)") }
            return out?.stringValue
        }
        if Thread.isMainThread { return run() }
        var result: String?
        DispatchQueue.main.sync { result = run() }
        return result
    }

    // MARK: - window raising (title-marker + AX)

    private static func activateApp(pid: pid_t?) {
        guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateAllWindows])
    }

    /// Identify the window showing `clientTty` by marking its title, then
    /// raise it and restore the title. Runs on a background queue.
    private static func raiseWindow(appPid: pid_t, clientTty: String) {
        let axApp = AXUIElementCreateApplication(appPid)
        let before = windowTitles(axApp)

        NSLog("TmuxFocuser: raising via tty \(clientTty); \(before.count) AX windows visible: \(before.map(\.title))")

        let nonce = "cn-focus-\(UUID().uuidString.prefix(8))"
        guard writeTitle(nonce, toTty: clientTty) else {
            NSLog("TmuxFocuser: writing title marker to \(clientTty) failed — activating app")
            activateApp(pid: appPid)
            return
        }

        var marked: AXUIElement?
        for _ in 0..<8 {
            usleep(60_000)
            if let w = windowTitles(axApp).first(where: { $0.title.contains(nonce) })?.window {
                marked = w
                break
            }
        }

        guard let window = marked else {
            // Marker never surfaced. Either AX can't see the window (e.g. it
            // lives on another Space) or the terminal ignored the escape.
            // The marker may still be painted on the hidden window's title —
            // overwrite it with something sane since we can't restore what we
            // never saw.
            NSLog("TmuxFocuser: marker \(nonce) not found among AX windows \(windowTitles(axApp).map(\.title)) — activating app")
            _ = writeTitle("tmux", toTty: clientTty)
            activateApp(pid: appPid)
            return
        }

        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: appPid)?.activate()

        // Restore the pre-marker title — tmux won't (set-titles is usually off).
        if let original = before.first(where: { CFEqual($0.window, window) })?.title {
            _ = writeTitle(original, toTty: clientTty)
        }

        // Re-raise once the app activation settles; cheap insurance for
        // cross-Space switches.
        usleep(120_000)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private static func windowTitles(_ axApp: AXUIElement) -> [(window: AXUIElement, title: String)] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return [] }
        return windows.map { w in
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            return (w, (t as? String) ?? "")
        }
    }

    /// Writes an OSC 2 (set window title) escape sequence directly to a tty
    /// device. This reaches the outer terminal without tmux in the way — the
    /// same mechanism tmux's own `set-titles` uses.
    private static func writeTitle(_ title: String, toTty path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // Strip control bytes (incl. the OSC terminators ESC/BEL) so a restored
        // window title can't re-inject terminal escape sequences.
        let clean = String(title.unicodeScalars.filter { $0.value >= 0x20 })
        let seq = "\u{1B}]2;\(clean)\u{07}"
        let bytes = Array(seq.utf8)
        return bytes.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress, buf.count) == buf.count
        }
    }
}
