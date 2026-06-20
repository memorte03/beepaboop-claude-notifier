import AppKit

/// The pixel-bell glyph as a menu-bar status icon. Drawn as a template image
/// (per the HIG): monochrome with alpha, so the system recolors it for
/// light/dark menu bars, tinting, and the pressed state. Resolution-
/// independent — the drawing handler re-runs at the backing scale, so cells
/// stay crisp on Retina.
enum MenuBarIcon {
    /// Same 12×12 grid as the app icon (scripts/make-icon.swift). Coarse on
    /// purpose — at menu-bar size a finer grid just looks like a blurry bell.
    private static let grid = [
        "....####....",
        "...######...",
        "..########..",
        "..########..",
        "..########..",
        "..########..",
        "..########..",
        "..########..",
        ".##########.",
        "############",
        "............",
        "....####....",
    ]

    static let template: NSImage = {
        // 12 cells at 1.25pt = 15pt. All cells go into ONE path filled once:
        // filling them as separate rects leaves antialiasing seams at shared
        // edges (each edge gets ~75% + 25% coverage composited twice, which
        // reads as a faint grid through the glyph).
        let cell: CGFloat = 1.25
        let side = cell * 12
        let img = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let path = NSBezierPath()
            for (row, line) in grid.enumerated() {
                for (col, ch) in line.enumerated() where ch == "#" {
                    path.appendRect(NSRect(x: CGFloat(col) * cell,
                                           y: CGFloat(row) * cell,
                                           width: cell, height: cell))
                }
            }
            NSColor.black.setFill()
            path.fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}
