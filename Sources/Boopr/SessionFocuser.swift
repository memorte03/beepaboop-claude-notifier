import Foundation
import ApplicationServices

/// Public "jump to session" entry point, kept for its call sites
/// (`OverlayView` onJump, `NotificationStore.jumpPending`). The focus logic now
/// lives in `FocusCoordinator`; this also retains the one-time Accessibility
/// prompt used at launch.
enum SessionFocuser {
    static func focus(req: NotifyRequest) {
        FocusCoordinator.focus(req: req)
    }

    /// Trigger a permission prompt by calling AX once. Returns whether trusted.
    @discardableResult
    static func ensureAccessibilityPermission() -> Bool {
        let opts: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(opts)
    }
}
