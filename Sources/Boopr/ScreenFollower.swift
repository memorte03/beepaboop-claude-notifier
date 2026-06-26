import AppKit

/// Keeps a floating panel on the display the user is currently looking at:
/// follows the cursor across screens (multi-display only) and re-anchors after a
/// Space switch. Shared by the overlay card and the pill bar so both behave
/// identically — the only per-window difference is how the target origin is
/// computed for a given screen.
@MainActor
final class ScreenFollower {
    private weak var window: NSWindow?
    /// Desired frame origin for the window on `screen` (nil ⇒ don't move).
    private let originForScreen: (NSScreen) -> NSPoint?

    private var mouseMonitor: Any?
    private var spaceObserver: NSObjectProtocol?

    /// The screen the window is currently anchored to.
    private(set) var currentScreen: NSScreen?

    init(window: NSWindow, originForScreen: @escaping (NSScreen) -> NSPoint?) {
        self.window = window
        self.originForScreen = originForScreen
    }

    /// Set the initial anchor from the cursor's screen (call when showing).
    @discardableResult
    func anchorToMouse() -> NSScreen? {
        currentScreen = ScreenUtil.underMouse()
        return currentScreen
    }

    func start() {
        // Following the cursor between displays only matters with >1 screen, so
        // skip the high-frequency per-mouse-move global monitor on a single
        // display (it allocates a CGEvent and scans screens on every move).
        if mouseMonitor == nil, NSScreen.screens.count > 1 {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow(spaceChange: false) }
            }
        }
        if spaceObserver == nil {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow(spaceChange: true) }
            }
        }
    }

    func stop() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        if let o = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            spaceObserver = nil
        }
    }

    private func follow(spaceChange: Bool) {
        guard let window, let screen = ScreenUtil.underMouse() else { return }
        if !spaceChange, screen.frame == currentScreen?.frame { return }
        currentScreen = screen
        guard let target = originForScreen(screen) else { return }

        if spaceChange {
            // After a Space switch, snap (the cross-Space show/hide already
            // handles the fade) and re-assert visibility so canJoinAllSpaces
            // keeps the window on top of the new Space.
            window.setFrameOrigin(target)
            window.orderFrontRegardless()
            return
        }

        // Cursor moved to another display: hide on the current screen, snap to
        // the new one, fade back in — this avoids the panel visibly sliding
        // across the gap between monitors.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                window.setFrameOrigin(target)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().alphaValue = 1
                }
            }
        })
    }
}
