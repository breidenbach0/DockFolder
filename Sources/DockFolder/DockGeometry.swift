import AppKit

enum DockEdge: Equatable {
    case bottom, left, right
}

/// Where the Dock is, read from the Dock's own preferences.
/// No Accessibility permission needed; the trade-off is that the panel is placed
/// relative to the pointer (which is on our icon when it's clicked), not the icon's exact frame.
struct DockGeometry: Equatable {
    var edge: DockEdge
    /// Largest size the Dock icons can reach (the magnified size, if magnification is on).
    var tileSize: CGFloat

    static func current() -> DockGeometry {
        let prefs = UserDefaults(suiteName: "com.apple.dock")
        let edge: DockEdge
        switch prefs?.string(forKey: "orientation") ?? "bottom" {
        case "left": edge = .left
        case "right": edge = .right
        default: edge = .bottom
        }
        var tile = CGFloat(prefs?.double(forKey: "tilesize") ?? 0)
        if tile <= 0 { tile = 48 }
        if prefs?.bool(forKey: "magnification") == true {
            tile = max(tile, CGFloat(prefs?.double(forKey: "largesize") ?? 0))
        }
        return DockGeometry(edge: edge, tileSize: tile)
    }

    @MainActor
    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    @MainActor
    static func isOverDock(_ point: NSPoint) -> Bool {
        guard let screen = screen(containing: point) else { return false }
        return current().isNearDock(point, screenFrame: screen.frame)
    }

    func isNearDock(_ point: NSPoint, screenFrame: NSRect) -> Bool {
        let reach = tileSize + 24
        switch edge {
        case .bottom: return point.y - screenFrame.minY <= reach
        case .left: return point.x - screenFrame.minX <= reach
        case .right: return screenFrame.maxX - point.x <= reach
        }
    }

    /// Frame for a panel of `size` that opens beside the Dock, centred on `anchor`
    /// (the pointer, which is over our icon), and kept fully on screen.
    func panelFrame(size: NSSize, anchor: NSPoint, screenFrame: NSRect, visibleFrame: NSRect) -> NSRect {
        let gap: CGFloat = 8
        // When the Dock is showing, visibleFrame stops at its edge. When it auto-hides,
        // visibleFrame reaches the screen edge, so leave room for the icons that slide in.
        var origin = NSPoint.zero
        switch edge {
        case .bottom:
            origin.x = anchor.x - size.width / 2
            origin.y = max(visibleFrame.minY, screenFrame.minY + tileSize + 12) + gap
        case .left:
            origin.x = max(visibleFrame.minX, screenFrame.minX + tileSize + 12) + gap
            origin.y = anchor.y - size.height / 2
        case .right:
            origin.x = min(visibleFrame.maxX, screenFrame.maxX - tileSize - 12) - gap - size.width
            origin.y = anchor.y - size.height / 2
        }
        origin.x = min(max(origin.x, visibleFrame.minX + gap), visibleFrame.maxX - size.width - gap)
        origin.y = min(max(origin.y, visibleFrame.minY + gap), visibleFrame.maxY - size.height - gap)
        return NSRect(origin: origin, size: size)
    }
}
