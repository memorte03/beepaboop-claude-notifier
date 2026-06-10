import AppKit
import ApplicationServices

/// Read-only checks for the two TCC permissions the app depends on, surfaced
/// in the menu bar so a user can see *why* jump-to-session is degraded instead
/// of it failing silently.
enum PermissionsStatus {
    enum State {
        case granted
        case denied
        case notDetermined   // macOS hasn't asked yet
        case unavailable     // target app not running — can't be queried

        var label: String {
            switch self {
            case .granted:       return "granted"
            case .denied:        return "denied"
            case .notDetermined: return "not asked yet"
            case .unavailable:   return "app not running"
            }
        }

        var symbol: String {
            switch self {
            case .granted: return "checkmark.circle.fill"
            case .denied:  return "xmark.circle.fill"
            case .notDetermined, .unavailable: return "questionmark.circle"
            }
        }
    }

    /// Accessibility — needed for the AX window-raise fallback and synthesized
    /// keystrokes outside tmux.
    static func accessibility() -> State {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Automation (Apple Events) for a specific target app — needed for the
    /// Ghostty cross-Space raise. Never prompts (askUserIfNeeded: false).
    static func automation(bundleID: String) -> State {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, false)
        switch Int(status) {
        case 0:                 return .granted        // noErr
        case -1744:             return .notDetermined  // errAEEventWouldRequireUserConsent
        case -600:              return .unavailable    // procNotFound
        default:                return .denied         // -1743 errAEEventNotPermitted etc.
        }
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openAutomationSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
