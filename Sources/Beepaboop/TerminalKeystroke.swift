import AppKit
import Foundation

/// Sends a keystroke to the terminal window where a Claude session is running.
/// Used for fire-and-forget permission flow: the hook returns "ask" so Claude
/// shows its native 1/2 prompt; clicking the overlay Approve/Deny posts "1\n"
/// or "2\n" back to that prompt.
///
/// Requires the Accessibility permission already granted for SessionFocuser.
enum TerminalKeystroke {
    /// `keyDigit` is "1" / "2" matching Claude Code's numbered prompt.
    static func sendDigit(_ keyDigit: String, to req: NotifyRequest) {
        // tmux path: deliver straight to the captured pane. Exact target, no
        // focus dance, no Space switching, no Accessibility needed.
        if TmuxFocuser.sendKeys([keyDigit, "Enter"], to: req) { return }

        // Fallback: blind-type via System Events into whatever we managed to
        // focus. First make sure the right terminal/window is up front; macOS
        // will also switch Spaces when we activate the app.
        SessionFocuser.focus(req: req)

        // Wait for the focus + Space-switch to land before sending the key.
        // 150ms is enough for cross-Space transitions; SSE on the same Space
        // would work in 30ms but we don't know which case we're in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let script = """
            tell application "System Events"
                keystroke "\(keyDigit)"
                keystroke return
            end tell
            """
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            do { try task.run() }
            catch { NSLog("osascript launch failed: \(error)") }
        }
    }
}
