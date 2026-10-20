import AppKit
import SwiftUI

/// Draws the Dock icon: a Liquid Glass tile with a 3×3 grid of the first nine app icons,
/// like an iPhone folder. The tile is see-through, so the Dock's own glass shows through it.
enum FolderIcon {
    static func make(from icons: [NSImage], tint: FolderTint = .clear, dark: Bool = false,
                     size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let tile = tileRect(in: rect)
            inLayer(context) {
                drawGlassTile(in: tile, canvas: rect, tint: tint.nsColor, dark: dark, context: context)
                if icons.isEmpty {
                    drawEmptySlots(in: tile, dark: dark, context: context)
                } else {
                    for (icon, frame) in zip(icons.prefix(9), slotFrames(in: tile)) {
                        icon.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
                    }
                }
            }
            return true
        }
    }

    /// DockFolder's own icon: a glass folder holding nine colourful apps.
    static func makeAppIcon(size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let tile = tileRect(in: rect)
            inLayer(context) {
                drawGlassTile(in: tile, canvas: rect, tint: nil, dark: false, context: context)
                let colors: [NSColor] = [.systemBlue, .systemPurple, .systemPink,
                                         .systemTeal, .systemIndigo, .systemOrange,
                                         .systemGreen, .systemYellow, .systemRed]
                for (color, frame) in zip(colors, slotFrames(in: tile)) {
                    drawMiniApp(in: appBody(in: frame), color: color, context: context)
                }
            }
            return true
        }
    }

    /// Writes DockFolder's icon as an .iconset folder, which `iconutil` turns into an .icns.
    static func writeAppIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try pngData(makeAppIcon(size: CGFloat(pixels)), pixels: pixels)
                    .write(to: directory.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Geometry

    /// Same proportions as standard macOS app icons: an 824pt squircle on a 1024pt canvas.
    private static func tileRect(in canvas: CGRect) -> CGRect {
        canvas.insetBy(dx: canvas.width * 100 / 1024, dy: canvas.height * 100 / 1024)
    }

    /// The continuous-corner squircle Apple uses for app icons.
    private static func squircle(_ rect: CGRect) -> CGPath {
        RoundedRectangle(cornerRadius: rect.width * 0.225, style: .continuous).path(in: rect).cgPath
    }

    /// The nine cells of the 3×3 grid. App icon images carry a transparent margin,
    /// so the visible icons sit further apart than the cells do.
    private static func slotFrames(in tile: CGRect) -> [CGRect] {
        let padding = tile.width * 0.07
        let gap = tile.width * 0.02
        let cell = (tile.width - padding * 2 - gap * 2) / 3
        return (0..<9).map { index in
            CGRect(x: tile.minX + padding + CGFloat(index % 3) * (cell + gap),
                   y: tile.maxY - padding - cell - CGFloat(index / 3) * (cell + gap),
                   width: cell, height: cell)
        }
    }

    /// Where an app icon's squircle sits inside its image.
    private static func appBody(in frame: CGRect) -> CGRect {
        frame.insetBy(dx: frame.width * 100 / 1024, dy: frame.height * 100 / 1024)
    }

    // MARK: - Drawing

    private static func drawGlassTile(in tile: CGRect, canvas: CGRect, tint: NSColor?, dark: Bool,
                                      context cg: CGContext) {
        let shape = squircle(tile)
        let unit = canvas.width / 1024   // all sizes below are in points of a 1024pt icon
        // Core Graphics shadows ignore the current transform, so scale them to device pixels.
        let shadowUnit = unit * hypot(cg.ctm.a, cg.ctm.b)

        // Shadow, cast by an opaque copy of the tile that's then cut away again,
        // so the see-through glass doesn't turn grey where the shadow sits beneath it.
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -10 * shadowUnit), blur: 28 * shadowUnit,
                     color: NSColor.black.withAlphaComponent(dark ? 0.5 : 0.28).cgColor)
        cg.addPath(shape)
        cg.setFillColor(NSColor.black.cgColor)
        cg.fillPath()
        cg.restoreGState()
        cg.saveGState()
        cg.setBlendMode(.clear)
        cg.addPath(shape)
        cg.fillPath()
        cg.restoreGState()

        cg.saveGState()
        cg.addPath(shape)
        cg.clip()

        // Body: frosted and see-through, lighter towards the top.
        let body = bodyColors(tint: tint, dark: dark)
        linearGradient(cg, [(0, body.top), (1, body.bottom)],
                       from: CGPoint(x: tile.midX, y: tile.maxY), to: CGPoint(x: tile.midX, y: tile.minY))

        // Light pooling under the top-left edge, as if it bends through the glass.
        radialGradient(cg, [(0, .white(dark ? 0.2 : 0.42)), (1, .white(0))],
                       center: CGPoint(x: tile.minX + tile.width * 0.3, y: tile.maxY),
                       radius: tile.width * 0.8)

        // Depth: a faint shade along the bottom.
        linearGradient(cg, [(0, .black(0)), (1, .black(dark ? 0.16 : 0.06))],
                       from: CGPoint(x: tile.midX, y: tile.minY + tile.height * 0.35),
                       to: CGPoint(x: tile.midX, y: tile.minY))

        // Thick-glass glow just inside the edge, strongest at the top. A ring around the
        // tile is filled outside the clip, so only its shadow falls inside.
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -14 * shadowUnit), blur: 44 * shadowUnit,
                     color: NSColor.white(dark ? 0.32 : 0.6).cgColor)
        let ring = CGMutablePath()
        ring.addRect(tile.insetBy(dx: -300 * unit, dy: -300 * unit))
        ring.addPath(shape)
        cg.addPath(ring)
        cg.setFillColor(NSColor.white.cgColor)
        cg.fillPath(using: .evenOdd)
        cg.restoreGState()

        // Specular rim: bright where the light hits (top left), catching it again bottom right.
        cg.addPath(shape)
        cg.setLineWidth(18 * unit)   // the clip keeps the inner half: a 9pt rim
        cg.replacePathWithStrokedPath()
        cg.clip()
        linearGradient(cg, [(0, .white(0.95)), (0.3, .white(0.4)), (0.5, .white(0.1)),
                            (0.72, .white(0.28)), (1, .white(0.75))],
                       from: CGPoint(x: tile.minX, y: tile.maxY), to: CGPoint(x: tile.maxX, y: tile.minY))
        cg.restoreGState()

        // Hairline, so the tile keeps its outline on a Dock of the same brightness.
        cg.saveGState()
        cg.addPath(shape)
        cg.setLineWidth(2.5 * unit)
        cg.setStrokeColor(dark ? NSColor.white(0.16).cgColor : NSColor.black(0.1).cgColor)
        cg.strokePath()
        cg.restoreGState()
    }

    private static func bodyColors(tint: NSColor?, dark: Bool) -> (top: NSColor, bottom: NSColor) {
        guard let tint = tint?.usingColorSpace(.sRGB) else {
            return dark ? (.white(0.3), .white(0.1)) : (.white(0.72), .white(0.36))
        }
        // Mostly opaque, so a colour reads as itself over a dark Dock rather than a muddy shade of it.
        let light = tint.blended(withFraction: dark ? 0.12 : 0.3, of: .white) ?? tint
        return dark
            ? (light.withAlphaComponent(0.88), tint.withAlphaComponent(0.76))
            : (light.withAlphaComponent(0.86), tint.withAlphaComponent(0.72))
    }

    private static func drawEmptySlots(in tile: CGRect, dark: Bool, context cg: CGContext) {
        cg.saveGState()
        cg.setFillColor(NSColor.white(dark ? 0.16 : 0.45).cgColor)
        for frame in slotFrames(in: tile) {
            cg.addPath(squircle(appBody(in: frame)))
        }
        cg.fillPath()
        cg.restoreGState()
    }

    private static func drawMiniApp(in body: CGRect, color: NSColor, context cg: CGContext) {
        let color = color.usingColorSpace(.sRGB) ?? color
        cg.saveGState()
        cg.addPath(squircle(body))
        cg.clip()
        linearGradient(cg, [(0, color.blended(withFraction: 0.35, of: .white) ?? color), (1, color)],
                       from: CGPoint(x: body.midX, y: body.maxY), to: CGPoint(x: body.midX, y: body.minY))
        cg.restoreGState()
    }

    /// Draws into an offscreen layer, so cutting the tile out of its own shadow
    /// can't punch through whatever the icon is drawn on top of.
    private static func inLayer(_ cg: CGContext, _ draw: () -> Void) {
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        draw()
        cg.endTransparencyLayer()
    }

    private static func linearGradient(_ cg: CGContext, _ stops: [(CGFloat, NSColor)], from: CGPoint, to: CGPoint) {
        guard let gradient = makeGradient(stops) else { return }
        cg.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func radialGradient(_ cg: CGContext, _ stops: [(CGFloat, NSColor)], center: CGPoint, radius: CGFloat) {
        guard let gradient = makeGradient(stops) else { return }
        cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    private static func makeGradient(_ stops: [(CGFloat, NSColor)]) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: stops.map { $0.1.cgColor } as CFArray,
                   locations: stops.map(\.0))
    }

    private static func pngData(_ image: NSImage, pixels: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CocoaError(.fileWriteUnknown)
        }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}

private extension NSColor {
    static func white(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }
    static func black(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha) }
}

extension NSAppearance {
    /// Folder glass is drawn lighter or darker to match the Dock.
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
