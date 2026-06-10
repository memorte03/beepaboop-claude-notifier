import AppKit

enum ScreenUtil {
    /// Screen the cursor currently sits on (or main as fallback).
    /// Uses CGEvent for a fresh cursor location — NSEvent.mouseLocation can be
    /// stale during Space switches or when no events have flowed recently.
    static func underMouse() -> NSScreen? {
        // CGEvent location is in flipped coords (top-left origin, y grows down)
        // relative to the main display. Convert to Cocoa coords (bottom-left
        // origin, y grows up) using the main display's height.
        let cg = CGEvent(source: nil)?.location ?? .zero
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let mouseLoc = NSPoint(x: cg.x, y: mainH - cg.y)
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? NSScreen.main
    }
}
