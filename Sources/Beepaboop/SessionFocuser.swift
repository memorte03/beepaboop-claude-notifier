import AppKit
import ApplicationServices

/// Activates the terminal window where a given Claude session is running.
/// Strategy:
///   1. If tmux identity was captured, TmuxFocuser selects the exact pane and
///      raises the window of the client displaying it (deterministic).
///   2. If terminalPid is provided, use NSRunningApplication.activate() — macOS auto-switches Space.
///   3. If windowTitle is provided, walk that app's AX window list and raise the matching window.
enum SessionFocuser {
    static func focus(req: NotifyRequest) {
        if TmuxFocuser.focus(req: req) { return }
        if let pid = req.terminalPid {
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                app.activate(options: [.activateAllWindows])
                if let title = req.windowTitle {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        raiseWindow(pid: pid_t(pid), titleSubstring: title)
                    }
                }
                return
            }
        }
        if let bundleID = req.terminalApp,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate(options: [.activateAllWindows])
            if let title = req.windowTitle {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    raiseWindow(pid: app.processIdentifier, titleSubstring: title)
                }
            }
        }
    }

    /// Uses Accessibility API to raise the window whose title contains `titleSubstring`.
    /// Requires Accessibility permission (System Settings → Privacy & Security → Accessibility).
    private static func raiseWindow(pid: pid_t, titleSubstring: String) {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard err == .success, let windows = windowsRef as? [AXUIElement] else { return }

        for window in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            if let title = titleRef as? String, title.contains(titleSubstring) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                return
            }
        }
    }

    /// Trigger a permission prompt by calling AX once. Returns whether trusted.
    @discardableResult
    static func ensureAccessibilityPermission() -> Bool {
        let opts: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(opts)
    }
}
