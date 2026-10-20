import AppKit
import SwiftUI

/// A folder's apps 9 to a page, like a folder on iPhone. Swipe with two fingers, click the dots,
/// or (in the panel above the Dock) use the arrow keys to turn the page.
struct FolderPages: View {
    @ObservedObject var store: FolderStore
    let arrowKeysTurnPages: Bool
    let onOpen: (FolderItem) -> Void

    @State private var page = 0
    /// How far the pages have followed the fingers in the current swipe…
    @State private var swipe: CGFloat = 0
    /// …and how far the fingers moved, before the stretch at the first and last page.
    @State private var fingers: CGFloat = 0

    /// Space between pages while they slide.
    private static let gap: CGFloat = 36

    var body: some View {
        let pages = store.items.chunked(into: FolderLayout.appsPerPage)
        let grid = FolderLayout.gridSize(itemCount: store.items.count, style: .pages)
        let current = min(page, max(pages.count - 1, 0))

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(pages.indices, id: \.self) { index in
                    AppGrid(items: pages[index], columns: 3, store: store, onOpen: onOpen)
                        .frame(width: grid.width, height: grid.height, alignment: .topLeading)
                }
            }
            .offset(x: -CGFloat(current) * (grid.width + Self.gap) + swipe)
            .frame(width: grid.width, height: grid.height, alignment: .leading)
            .clipped()
            .background {
                PageSwipeCatcher(
                    isEnabled: pages.count > 1,
                    arrowKeys: arrowKeysTurnPages,
                    onSwipe: { delta in
                        fingers += delta
                        let pastTheEnd = (current == 0 && fingers > 0) || (current == pages.count - 1 && fingers < 0)
                        swipe = pastTheEnd ? fingers / 3 : fingers
                    },
                    onSwipeEnd: { velocity in
                        var target = current
                        if fingers < -grid.width * 0.2 || velocity < -6 { target += 1 }
                        if fingers > grid.width * 0.2 || velocity > 6 { target -= 1 }
                        fingers = 0
                        turn(to: target, of: pages.count)
                    },
                    onStep: { step in turn(to: current + step, of: pages.count) }
                )
            }

            if pages.count > 1 {
                PageDots(count: pages.count, current: current) { turn(to: $0, of: pages.count) }
            }
        }
    }

    private func turn(to index: Int, of pageCount: Int) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            page = min(max(index, 0), pageCount - 1)
            swipe = 0
        }
    }
}

/// Which page is showing. Click a dot to go to its page.
private struct PageDots: View {
    let count: Int
    let current: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                Button { onSelect(index) } label: {
                    Circle()
                        .fill(Color.primary.opacity(index == current ? 0.8 : 0.25))
                        .frame(width: 7, height: 7)
                        .padding(5)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Page \(index + 1)")
                .accessibilityLabel("Page \(index + 1) of \(count)")
                .accessibilityAddTraits(index == current ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: FolderLayout.pageDotsHeight, alignment: .bottom)
        .animation(.easeOut(duration: 0.2), value: current)
    }
}

/// Passes horizontal swipes over the pages to SwiftUI. A two-finger swipe arrives as scroll
/// events, which SwiftUI's gestures don't see, so this view watches for them.
private struct PageSwipeCatcher: NSViewRepresentable {
    let isEnabled: Bool
    let arrowKeys: Bool
    let onSwipe: (CGFloat) -> Void
    let onSwipeEnd: (CGFloat) -> Void
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> SwipeCatcherView { SwipeCatcherView() }

    func updateNSView(_ view: SwipeCatcherView, context: Context) {
        view.isEnabled = isEnabled
        view.arrowKeys = arrowKeys
        view.onSwipe = onSwipe
        view.onSwipeEnd = onSwipeEnd
        view.onStep = onStep
    }
}

final class SwipeCatcherView: NSView {
    var isEnabled = false
    var arrowKeys = false
    var onSwipe: (CGFloat) -> Void = { _ in }
    var onSwipeEnd: (CGFloat) -> Void = { _ in }
    var onStep: (Int) -> Void = { _ in }

    private enum Gesture { case undecided, horizontal, ignored }
    private var gesture = Gesture.ignored
    private var recentDeltas: [CGFloat] = []
    private var monitor: Any?

    // Clicks go through to the apps underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    /// Returns nil for events it used up.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isEnabled, let window, event.window === window else { return event }
        return event.type == .keyDown ? handleKey(event, in: window) : handleScroll(event)
    }

    private func handleKey(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
        guard arrowKeys, window.isKeyWindow,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
        switch event.keyCode {
        case 123: onStep(-1); return nil   // ←
        case 124: onStep(1); return nil    // →
        default: return event
        }
    }

    /// Internal so tests can feed it scroll events; returns nil for events it used up.
    func handleScroll(_ event: NSEvent) -> NSEvent? {
        let isOverPages = bounds.contains(convert(event.locationInWindow, from: nil))

        // A mouse wheel turned sideways (or with Shift): one notch, one page.
        if !event.hasPreciseScrollingDeltas {
            guard isOverPages, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
            onStep(event.scrollingDeltaX < 0 ? 1 : -1)
            return nil
        }

        // The glide after a swipe: used up along with the swipe.
        if !event.momentumPhase.isEmpty {
            return gesture == .horizontal ? nil : event
        }

        if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
            gesture = isOverPages ? .undecided : .ignored
            recentDeltas = []
        }
        if gesture == .undecided {
            let dx = abs(event.scrollingDeltaX), dy = abs(event.scrollingDeltaY)
            if dx > 0 || dy > 0 { gesture = dx > dy ? .horizontal : .ignored }
        }
        // Vertical scrolls, and swipes that started elsewhere, belong to someone else.
        guard gesture == .horizontal else { return event }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let velocity = recentDeltas.isEmpty ? 0 : recentDeltas.reduce(0, +) / CGFloat(recentDeltas.count)
            onSwipeEnd(event.phase.contains(.cancelled) ? 0 : velocity)
            return nil
        }
        recentDeltas = Array((recentDeltas + [event.scrollingDeltaX]).suffix(3))
        onSwipe(event.scrollingDeltaX)
        return nil
    }
}

extension Array {
    /// The array cut into runs of `size`; the last one may be shorter.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
