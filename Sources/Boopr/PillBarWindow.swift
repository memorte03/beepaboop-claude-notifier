import AppKit
import SwiftUI

/// Thin non-activating panel hosting the pill bar, pinned top-center of the
/// screen the mouse is on, visible on every Space (same recipe as
/// OverlayWindow but sized to fit its content).
final class PillBarWindow: NSPanel {
    private var contentSize = NSSize(width: 10, height: 10)
    private lazy var follower = ScreenFollower(window: self) { [weak self] screen in
        self?.originForScreen(screen)
    }
    /// Extra distance from the top, set while the overlay card is visible so
    /// the bar sits below it instead of overlapping.
    var topOffset: CGFloat = 0 {
        didSet { if isVisible { reposition() } }
    }

    init(rootView: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: contentSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        rootView.frame = NSRect(origin: .zero, size: contentSize)
        rootView.autoresizingMask = [.width, .height]
        contentView = rootView
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// SwiftUI reports its natural size; window adopts it, keeping top-center.
    func updateContentSize(_ size: CGSize) {
        guard size != .zero else { return }
        contentSize = NSSize(width: size.width, height: size.height)
        if isVisible { reposition() }
    }

    func show() {
        follower.anchorToMouse()
        reposition()
        orderFrontRegardless()
        follower.start()
    }

    func hide() {
        follower.stop()
        orderOut(nil)
    }

    /// Top-center anchor on a given screen (origin only; size is contentSize).
    private func originForScreen(_ screen: NSScreen) -> NSPoint? {
        let frame = screen.visibleFrame
        let margin: CGFloat = 10
        return NSPoint(
            x: frame.midX - contentSize.width / 2,
            y: frame.maxY - contentSize.height - margin - topOffset
        )
    }

    private func reposition() {
        guard let screen = follower.currentScreen ?? ScreenUtil.underMouse(),
              let origin = originForScreen(screen) else { return }
        setFrame(NSRect(origin: origin, size: contentSize), display: true)
    }
}
