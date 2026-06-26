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

    private lazy var follower = ScreenFollower(window: self) { [weak self] screen in
        self?.targetTopCenter(on: screen)
    }
    private var currentScreen: NSScreen? { follower.currentScreen }

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
        follower.anchorToMouse()
        if let target = targetTopCenter(on: currentScreen) {
            setFrameOrigin(target)
            Debug.log("overlay show → screen=\(currentScreen?.localizedName ?? "?") target=\(NSStringFromPoint(target))")
        }
        alphaValue = 1
        orderFrontRegardless()
        follower.start()
    }

    /// Order front + immediately order out, so the window's surface/layer
    /// is initialized before the first user-visible show. Avoids first-show
    /// SwiftUI transition glitches.
    func prewarm() {
        follower.anchorToMouse()
        if let target = targetTopCenter(on: currentScreen) { setFrameOrigin(target) }
        alphaValue = 0
        orderFrontRegardless()
        displayIfNeeded()
        orderOut(nil)
        alphaValue = 1
    }

    override func orderOut(_ sender: Any?) {
        follower.stop()
        super.orderOut(sender)
    }
}
