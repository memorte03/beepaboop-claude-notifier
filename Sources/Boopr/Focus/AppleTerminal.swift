import AppKit

/// Apple Terminal (Terminal.app) native focus. Each Terminal tab exposes its
/// `tty`, so we match against the controlling tty (direct sessions) or the tmux
/// client tty (tmux-in-Terminal) — selecting the exact tab and raising its
/// window, no AX or marker needed. Zero-config: no per-terminal setting.
enum AppleTerminalControl {
    static let bundleID = "com.apple.Terminal"

    /// Select the tab attached to `tty`, raise its window, and activate.
    static func focusTty(_ tty: String) -> Bool {
        let safe = tty.replacingOccurrences(of: "\"", with: "")
        let script = """
        tell application id "\(bundleID)"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(safe)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return ""
        """
        return AppleScript.run(script) == "ok"
    }

    /// Bring Terminal forward without targeting a tab (self-activation).
    static func activate() -> Bool {
        AppleScript.runVoid("tell application id \"\(bundleID)\" to activate")
    }
}

/// Rung 1: Apple Terminal via AppleScript — selects the exact tab by its tty and
/// raises the window (cross-Space). Handles bare, multi-tab, and tmux-in-Terminal
/// uniformly, so it supersedes the marker-AX raiser for Terminal.
struct AppleTerminalRaiser: WindowRaiser {
    let rung = 1
    func canHandle(_ ctx: RaiseContext) -> Bool { ctx.bundleID == AppleTerminalControl.bundleID }
    func raise(_ ctx: RaiseContext) -> Bool {
        if let tty = ctx.markTty, AppleTerminalControl.focusTty(tty) { return true }
        return AppleTerminalControl.activate()
    }
}
