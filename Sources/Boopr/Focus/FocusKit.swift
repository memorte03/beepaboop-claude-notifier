import AppKit
import ApplicationServices

/// Everything a `WindowRaiser` needs to bring the right OS window forward.
///
/// The two identification strategies are mutually exclusive per request:
///   - `markTty != nil`  → identify by writing an OSC-2 title marker to that tty
///     and finding the AX/AppleScript window carrying it (the multiplexer path).
///   - `titleHint != nil` → identify by matching an existing window title
///     substring (the non-multiplexer path).
struct RaiseContext: Sendable {
    let req: NotifyRequest
    let pid: pid_t?
    let bundleID: String?
    /// tty to mark for OSC-2/AX identification (e.g. a tmux client tty). nil for
    /// the non-multiplexer path, which matches by title instead. Used by the
    /// Ghostty/marker raisers introduced in Phase 1b.
    let markTty: String?
    /// Window-title substring to match (non-multiplexer identification).
    let titleHint: String?

    /// The terminal app: by pid when it's still running, else by bundle id.
    var app: NSRunningApplication? {
        if let pid, let a = NSRunningApplication(processIdentifier: pid) { return a }
        if let bundleID {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
        return nil
    }
}

/// Raises the OS window for a focus target. The coordinator tries the registered
/// raisers in ascending `rung` order (most → least deterministic) until one
/// returns true. Each new terminal becomes a new conformer — additive.
protocol WindowRaiser: Sendable {
    var rung: Int { get }
    func canHandle(_ ctx: RaiseContext) -> Bool
    func raise(_ ctx: RaiseContext) -> Bool
}

/// AX/activation helpers shared by raisers. Moved verbatim from the old
/// `SessionFocuser` so every raiser shares one implementation; Phase 1b folds
/// the tmux `writeTitle`/`windowTitles` marker helpers in here too.
enum RaiseSupport {
    static func activate(_ app: NSRunningApplication) {
        app.activate(options: [.activateAllWindows])
    }

    /// Writes an OSC 2 (set window title) escape sequence directly to a tty
    /// device. This reaches the outer terminal without tmux in the way — the same
    /// mechanism tmux's own `set-titles` uses — so the AX/AppleScript window
    /// carrying the marker can be found. Shared by the Ghostty and AX-marker
    /// raisers.
    @discardableResult
    static func writeTitle(_ title: String, toTty path: String) -> Bool {
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

    /// Raise the window whose title contains `titleSubstring`. Requires the
    /// Accessibility permission (System Settings → Privacy → Accessibility).
    static func raiseWindowByTitle(pid: pid_t, titleSubstring: String) {
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
}
