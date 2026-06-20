import AppKit
import SwiftUI

/// A floating panel that appears on every Space and does not steal focus.
final class OverlayWindow: NSPanel {
    static let panelWidth: CGFloat = 520
    static let minPanelHeight: CGFloat = 200
    static let maxPanelHeight: CGFloat = 960   // accommodates 800px diff + ~160 for chrome
    static let panelSize = NSSize(width: panelWidth, height: minPanelHeight)
    private var desiredHeight: CGFloat = minPanelHeight

    init(rootView: NSView) {
        let rect = NSRect(origin: .zero, size: OverlayWindow.panelSize)
        super.init(contentRect: rect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false   // SwiftUI card draws its own shadow; window shadow traces the rect window outline
        self.level = .statusBar
        self.isMovable = false
        self.isMovableByWindowBackground = false
        // canJoinAllSpaces makes the window appear on every Space; fullScreenAuxiliary
        // lets it coexist with a fullscreen app. Drop `.stationary` — that's for
        // dock-like single-instance pinning and tends to fight canJoinAllSpaces.
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
        rootView.frame = rect
        rootView.autoresizingMask = [.width, .height]
        self.contentView = rootView
        self.ignoresMouseEvents = false
        // Don't let NSHostingView's intrinsic size shrink the window when
        // the SwiftUI body is empty.
        self.contentMinSize = OverlayWindow.panelSize
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var mouseMonitor: Any?
    private var spaceObserver: NSObjectProtocol?
    private var currentScreen: NSScreen?

    /// Extra distance from the top, set while the pill bar is visible so the
    /// card slides in below it instead of overlapping.
    var topOffset: CGFloat = 0 {
        didSet {
            guard isVisible, oldValue != topOffset,
                  let target = targetTopCenter(on: currentScreen) else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrameOrigin(target)
            }
        }
    }

    /// Top-center anchor on a given screen.
    private func targetTopCenter(on screen: NSScreen?) -> NSPoint? {
        guard let frame = screen?.visibleFrame else { return nil }
        let size = self.frame.size
        let margin: CGFloat = 16
        return NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - margin - topOffset
        )
    }

    /// Resize the panel to a new content height while keeping the TOP edge
    /// pinned to its current position (so the card doesn't appear to jump).
    /// Called by the SwiftUI content-size preference change.
    func updateContentHeight(_ requested: CGFloat, animated: Bool = true) {
        let clamped = max(OverlayWindow.minPanelHeight,
                          min(requested, OverlayWindow.maxPanelHeight))
        guard abs(clamped - desiredHeight) > 0.5 else { return }
        desiredHeight = clamped

        let oldTop = self.frame.origin.y + self.frame.size.height
        let newOrigin = NSPoint(x: self.frame.origin.x, y: oldTop - clamped)
        let newFrame = NSRect(origin: newOrigin,
                              size: NSSize(width: OverlayWindow.panelWidth, height: clamped))
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(newFrame, display: true)
            }
        } else {
            setFrame(newFrame, display: true)
        }
    }

    /// Just position + orderFront. SwiftUI owns the animation.
    func show() {
        setContentSize(NSSize(width: OverlayWindow.panelWidth, height: desiredHeight))
        currentScreen = ScreenUtil.underMouse()
        if let target = targetTopCenter(on: currentScreen) {
            setFrameOrigin(target)
            Debug.log("overlay show → screen=\(currentScreen?.localizedName ?? "?") target=\(NSStringFromPoint(target))")
        }
        alphaValue = 1
        orderFrontRegardless()
        startMouseTracking()
    }

    /// Order front + immediately order out, so the window's surface/layer
    /// is initialized before the first user-visible show. Avoids first-show
    /// SwiftUI transition glitches.
    func prewarm() {
        currentScreen = ScreenUtil.underMouse()
        if let target = targetTopCenter(on: currentScreen) { setFrameOrigin(target) }
        alphaValue = 0
        orderFrontRegardless()
        displayIfNeeded()
        orderOut(nil)
        alphaValue = 1
    }

    override func orderOut(_ sender: Any?) {
        stopMouseTracking()
        super.orderOut(sender)
    }

    // MARK: - dynamic screen follow

    private func startMouseTracking() {
        // Following the cursor between displays only matters with >1 screen, so
        // skip the high-frequency per-mouse-move global monitor on a single
        // display (it allocates a CGEvent and scans screens on every move).
        if mouseMonitor == nil, NSScreen.screens.count > 1 {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                MainActor.assumeIsolated { self?.followMouseToCurrentScreen() }
            }
        }
        if spaceObserver == nil {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                // After a Space switch, re-anchor to wherever the mouse is on
                // the new Space, and re-assert visibility so canJoinAllSpaces
                // shows us on top.
                MainActor.assumeIsolated {
                    self?.followMouseToCurrentScreen(force: true)
                    self?.orderFrontRegardless()
                }
            }
        }
    }

    private func stopMouseTracking() {
        if let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
        }
        if let o = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            spaceObserver = nil
        }
    }

    private func followMouseToCurrentScreen(force: Bool = false) {
        guard let screen = ScreenUtil.underMouse() else { return }
        if !force, screen.frame == currentScreen?.frame { return }
        guard let target = targetTopCenter(on: screen) else { return }
        currentScreen = screen
        Debug.log("overlay follow → screen=\(screen.localizedName) target=\(NSStringFromPoint(target))")

        if force {
            // Space switch — snap without fade, the cross-Space behaviour
            // already hides/shows the window for us.
            setFrameOrigin(target)
            return
        }

        // Hide on the current screen, snap to the new screen, fade back in.
        // This avoids the panel "sliding" across the gap between monitors,
        // which looks broken on multi-display setups.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // NSAnimationContext completion runs on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setFrameOrigin(target)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.animator().alphaValue = 1
                }
            }
        })
    }
}
