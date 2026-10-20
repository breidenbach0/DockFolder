import AppKit
import Combine
import SwiftUI

/// Borderless panel that can still take keyboard focus (for Esc).
final class FolderPanel: NSPanel {
    static func make() -> FolderPanel {
        let panel = FolderPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                                styleMask: [.borderless],
                                backing: .buffered,
                                defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false   // PanelController decides when to close
        return panel
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the panel's glass grow out of the Dock icon when it opens.
@MainActor
final class PanelPresentation: ObservableObject {
    @Published var isShown = true
    /// Where the panel grows from: the Dock side, under the pointer.
    @Published var anchor = UnitPoint.bottom
}

struct FolderPanelView: View {
    @ObservedObject var store: FolderStore
    @ObservedObject var presentation: PanelPresentation
    let drawsGlass: Bool
    /// Transparent room around the glass, for the glass's own shadow.
    let margin: CGFloat
    let onOpen: (FolderItem) -> Void
    let onAdd: () -> Void

    var body: some View {
        FolderView(store: store, drawsGlass: drawsGlass, onOpen: onOpen, onAdd: onAdd)
            .scaleEffect(presentation.isShown ? 1 : 0.86, anchor: presentation.anchor)
            .padding(margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows and hides the folder grid above the Dock icon.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    var onAddApps: () -> Void = {}
    private(set) var isOpen = false
    /// Where the panel opens from: the pointer position when the Dock icon was clicked.
    private(set) var anchor = NSPoint.zero

    private let store: FolderStore
    private let panel: FolderPanel
    private let presentation: PanelPresentation
    private let hosting: NSHostingView<FolderPanelView>
    private var keyMonitor: Any?
    private var itemsSubscription: AnyCancellable?
    private var lastClose = Date.distantPast

    /// From macOS 26 SwiftUI draws Liquid Glass itself, so the glass can grow with the content.
    /// Before that the window draws a blur behind the content instead.
    private static var usesLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Liquid Glass casts its own soft shadow, so the window is this much larger than the glass
    /// to let it fade out. The window casts no shadow itself: around see-through glass it
    /// would trace the window's rectangle.
    private static var glassMargin: CGFloat { usesLiquidGlass ? 28 : 0 }

    init(store: FolderStore) {
        self.store = store
        self.panel = FolderPanel.make()
        let presentation = PanelPresentation()
        self.presentation = presentation
        self.hosting = NSHostingView(rootView: FolderPanelView(store: store, presentation: presentation,
                                                               drawsGlass: Self.usesLiquidGlass,
                                                               margin: Self.glassMargin,
                                                               onOpen: { _ in }, onAdd: {}))
        super.init()

        hosting.rootView = FolderPanelView(
            store: store,
            presentation: presentation,
            drawsGlass: Self.usesLiquidGlass,
            margin: Self.glassMargin,
            onOpen: { [weak self] item in self?.open(item) },
            onAdd: { [weak self] in self?.onAddApps() }
        )
        panel.hasShadow = !Self.usesLiquidGlass
        hosting.sizingOptions = []   // the window is sized from FolderLayout, not measured
        panel.contentView = Self.usesLiquidGlass ? hosting : Self.makeBackground(containing: hosting)
        panel.delegate = self

        // Grow or shrink the open panel as apps are added or removed.
        itemsSubscription = store.$items.dropFirst().sink { [weak self] items in
            guard let self, self.isOpen else { return }
            self.applyFrame(itemCount: items.count)
        }
    }

    func toggle() {
        if isOpen {
            close(hideApp: true)
        } else if Date().timeIntervalSince(lastClose) > 0.3 {
            // If the same click on the Dock icon already closed us (by taking key status
            // away first), don't immediately reopen.
            show()
        }
    }

    func show(near point: NSPoint? = nil) {
        anchor = point ?? NSEvent.mouseLocation
        applyFrame(itemCount: store.items.count)
        guard !isOpen else { return }

        isOpen = true
        NSApp.activate(ignoringOtherApps: true)
        presentation.isShown = !Self.usesLiquidGlass
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()

        // Next turn of the run loop, so SwiftUI has drawn the small state to grow from.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOpen else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.74)) {
                self.presentation.isShown = true
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                self.panel.animator().alphaValue = 1
            }
        }
    }

    /// `hideApp` hands focus back to the app the user was in (after Esc or a second click
    /// on the Dock icon). Not wanted when another app is already taking focus.
    /// `animated` fades the panel out; not wanted when a dialog is about to take its place.
    func close(hideApp: Bool, animated: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        lastClose = Date()
        removeKeyMonitor()
        if hideApp || !animated {
            // Hiding the app takes the panel with it at once, so there's nothing to fade.
            panel.orderOut(nil)
            if hideApp { NSApp.hide(nil) }
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }   // reopened while fading out
                self.panel.orderOut(nil)
            }
        })
    }

    // Clicking anywhere outside the panel makes it lose key status.
    func windowDidResignKey(_ notification: Notification) {
        close(hideApp: false)
    }

    // MARK: - Private

    private func open(_ item: FolderItem) {
        guard store.open(item) else {
            NSSound.beep()
            return
        }
        close(hideApp: false)
    }

    private func applyFrame(itemCount: Int) {
        guard let screen = DockGeometry.screen(containing: anchor) else { return }
        let dock = DockGeometry.current()
        let glass = dock.panelFrame(
            size: FolderLayout.panelSize(itemCount: itemCount),
            anchor: anchor,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        presentation.anchor = Self.growAnchor(edge: dock.edge, pointer: anchor, frame: glass)
        panel.setFrame(glass.insetBy(dx: -Self.glassMargin, dy: -Self.glassMargin), display: true)
        if panel.hasShadow { panel.invalidateShadow() }
    }

    /// The point on the panel's Dock side that's closest to the pointer, in SwiftUI's
    /// top-down unit coordinates.
    private static func growAnchor(edge: DockEdge, pointer: NSPoint, frame: NSRect) -> UnitPoint {
        let x = min(max((pointer.x - frame.minX) / frame.width, 0), 1)
        let y = 1 - min(max((pointer.y - frame.minY) / frame.height, 0), 1)
        switch edge {
        case .bottom: return UnitPoint(x: x, y: 1)
        case .left: return UnitPoint(x: 0, y: y)
        case .right: return UnitPoint(x: 1, y: y)
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // 53 = Esc
            self?.close(hideApp: true)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Before macOS 26: a blur behind the window, rounded with a mask.
    private static func makeBackground(containing content: NSView) -> NSView {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = roundedMask(radius: FolderLayout.cornerRadius)

        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        return background
    }

    /// Stretchable rounded-rect mask, the supported way to round an NSVisualEffectView.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
