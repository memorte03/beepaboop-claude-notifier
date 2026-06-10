// Generates Resources/AppIcon.iconset.
// Run: swift scripts/make-icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
//
// Design: chunky pixel-grid notification bell (same style as the Claude
// mascot) matched to the installed Claude.app icon, measured directly from
// /Applications/Claude.app's electron.icns:
//   - 824×824 tile on the 1024 canvas (Apple's standard icon grid) + shadow
//   - background gradient #D97756 (top) → #DA6A47 (bottom)
//   - near-white glyph #FEFCFB filling ~73% of the tile
//
// Each iconset rendition is drawn natively at its pixel size with cell edges
// snapped to the pixel grid — downscaling a 1024 master smears the pixel-art
// steps into a blur, which defeats the style.
import AppKit

let bgTop = NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x56 / 255.0, alpha: 1)
let bgBottom = NSColor(srgbRed: 0xDA / 255.0, green: 0x6A / 255.0, blue: 0x47 / 255.0, alpha: 1)
let fg = NSColor(srgbRed: 0xFE / 255.0, green: 0xFC / 255.0, blue: 0xFB / 255.0, alpha: 1)

// 12×12 grid, written top-down. Coarse on purpose: at this resolution the
// steps stay visible even at Dock size, which is what sells the pixel style.
let bellGrid = [
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

/// Apple icon grid: the tile is 824/1024 of the canvas.
let tileFraction: CGFloat = 824.0 / 1024.0
/// Corner radius ratio of the macOS squircle (185.4 / 824).
let cornerRatio: CGFloat = 185.4 / 824.0
/// Glyph span as a fraction of the tile (Claude.app's starburst is 0.73).
let glyphFraction: CGFloat = 0.72

func renderPNG(pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(pixels)
    let tileSize = (s * tileFraction).rounded()
    let inset = ((s - tileSize) / 2).rounded()
    let tile = NSRect(x: inset, y: inset, width: tileSize, height: tileSize)
    let r = tileSize * cornerRatio
    let squircle = NSBezierPath(roundedRect: tile, xRadius: r, yRadius: r)

    // Standard macOS icon drop shadow, scaled with the rendition.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s / 1024)
    shadow.shadowBlurRadius = 20 * s / 1024
    shadow.set()
    bgTop.setFill()
    squircle.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(starting: bgTop, ending: bgBottom)!.draw(in: squircle, angle: -90)

    let n = bellGrid.count
    let cell = tileSize * glyphFraction / CGFloat(n)
    let origin = (s - cell * CGFloat(n)) / 2
    // Snap cell edges to whole pixels; adjacent cells share an edge, so the
    // grid stays seamless and razor-crisp at every size.
    func edge(_ i: Int) -> CGFloat { (origin + cell * CGFloat(i)).rounded() }
    fg.setFill()
    for (row, line) in bellGrid.enumerated() {
        let yTop = edge(n - row)        // grid is top-down; flip to bottom-up
        let yBot = edge(n - row - 1)
        for (col, ch) in line.enumerated() where ch == "#" {
            NSRect(x: edge(col), y: yBot,
                   width: edge(col + 1) - edge(col),
                   height: yTop - yBot).fill()
        }
    }
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let repoRoot = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().deletingLastPathComponent()
let iconset = repoRoot.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    renderPNG(pixels: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    renderPNG(pixels: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote \(iconset.path)")
