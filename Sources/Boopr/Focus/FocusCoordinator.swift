import AppKit

/// Single entry point for "bring the Claude session's surface forward" and for
/// delivering the permission keystroke. It composes the two orthogonal layers:
/// inner pane selection (multiplexer) and OS window raise (`WindowRaiser`s).
///
/// The tmux pane-select + window-raise still run as the proven, fused
/// `TmuxFocuser.focus` unit. Everything else flows through the `WindowRaiser`
/// ladder: Ghostty (rung 1, AppleScript — exact tab via the captured tty, else
/// self-activate), then the AX-title and app-activation fallbacks.
enum FocusCoordinator {
    /// Window raisers in ascending rung order (most → least deterministic).
    private static let raisers: [WindowRaiser] = [
        GhosttyRaiser(),
        TitleAXRaiser(),
        AppActivationRaiser(),
    ].sorted { $0.rung < $1.rung }

    /// Raise the terminal window the session runs in (jump-to-session).
    static func focus(req: NotifyRequest) {
        // Deterministic multiplexer path: select the exact pane and raise the
        // window of the client showing it (self-contained; raises off-main).
        if TmuxFocuser.focus(req: req) { return }

        // Non-multiplexer path: the session's controlling tty (`req.tty`) lets the
        // Ghostty raiser mark + focus the exact tab; other terminals fall to
        // AX-title / app-activation.
        let ctx = RaiseContext(
            req: req,
            pid: req.terminalPid.map { pid_t($0) },
            bundleID: req.terminalApp,
            markTty: req.tty,
            titleHint: req.windowTitle
        )
        // Off the main thread: Ghostty's AppleScript poll (usleep) and the AX
        // work must not block the notification click handler.
        DispatchQueue.global(qos: .userInitiated).async {
            for raiser in raisers where raiser.canHandle(ctx) {
                if raiser.raise(ctx) { return }
            }
        }
    }

    /// Deliver literal keys to the session's pane (the permission 1/2 answer).
    /// Returns false when there's no deterministic multiplexer target, so the
    /// caller can fall back to focus + synthesized keystrokes.
    @discardableResult
    static func sendKeys(_ keys: [String], to req: NotifyRequest) -> Bool {
        TmuxFocuser.sendKeys(keys, to: req)
    }
}
