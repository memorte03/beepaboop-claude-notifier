import SwiftUI
import AppKit

/// SwiftUI scroll view with a forced thin overlay scrollbar — independent of
/// the user's "Show scroll bars" system preference. Used by DiffView.
struct ThinScrollView<Content: View>: NSViewRepresentable {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay        // thin floating bar (vs. legacy thick rail)
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        scroll.scrollerKnobStyle = .light

        let scroller = ThinScroller()
        scroller.controlSize = .mini
        scroll.verticalScroller = scroller

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = hosting
        let contentView = scroll.contentView   // already an NSClipView
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: contentView.topAnchor),
        ])
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let hosting = scroll.documentView as? NSHostingView<Content> {
            hosting.rootView = content
        }
    }
}

/// Subclass that draws a thinner knob than the default overlay scroller.
final class ThinScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat {
        return 6   // total track width — tighter than mini default (~11)
    }

    override func drawKnob() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = rect(for: .knob).insetBy(dx: 1.5, dy: 1.5)
        let radius = r.width / 2
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        ctx.beginPath()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight: Bool) {
        // No track background — keeps the diff visually clean.
    }
}
