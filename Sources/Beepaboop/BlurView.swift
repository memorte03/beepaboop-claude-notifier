import SwiftUI
import AppKit

/// Wraps NSVisualEffectView so SwiftUI views can use behind-window blur —
/// the same effect Raycast and LookAway use.
struct BlurView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = emphasized
        // Force dark vibrancy regardless of the user's system appearance so the
        // overlay is consistent.
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.isEmphasized = emphasized
    }
}
