import AppKit
import SwiftUI

/// Moving an app to another place in its folder. The app follows the pointer and the others make
/// room; holding it at either side of the folder turns the page. Nothing is saved until the app
/// is let go, so moving it stays smooth.
@MainActor
final class Rearrangement: ObservableObject {
    /// The app being moved, or settling into its new place after being let go.
    @Published private(set) var item: FolderItem?
    /// The folder's apps, in the order shown meanwhile.
    @Published private(set) var order: [FolderItem] = []
    /// The side the app is held at to turn the page: -1 for the left, 1 for the right.
    @Published private(set) var turnSide: Int?
    /// Where the app is drawn. An object of its own, so that following the pointer redraws only
    /// the app being moved, not every app in the folder.
    let tile = MovingTile()
    /// The pointer, in the folder's coordinates.
    private(set) var pointer = CGPoint.zero
    /// From the pointer to the middle of the app, so the app doesn't jump when it's picked up.
    private var grab = CGSize.zero
    private var isSettling = false
    /// Counts moves, so a late end to one move's settling leaves the next move alone.
    private var moves = 0
    private let turner = PageTurner()

    /// The app being moved, until it's let go.
    var movingItem: FolderItem? { isSettling ? nil : item }

    func pickUp(_ item: FolderItem, from items: [FolderItem], at pointer: CGPoint, center: CGPoint) {
        settle()
        FolderDrag.log.notice("moving \(item.path, privacy: .public)")
        self.item = item
        order = items
        self.pointer = pointer
        grab = CGSize(width: center.x - pointer.x, height: center.y - pointer.y)
        tile.center = center
        tile.isLifted = true
    }

    /// Moves the app with the pointer and into `place` in the folder. While it's held at a
    /// side, `turn` turns the page that way after a moment, and again every so often.
    func follow(_ pointer: CGPoint, to place: Int?, turning side: Int?, turn: @escaping (Int) -> Void) {
        guard let item = movingItem else { return }
        self.pointer = pointer
        tile.center = CGPoint(x: pointer.x + grab.width, y: pointer.y + grab.height)
        if let place, order.firstIndex(of: item) != place {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                order = order.moving(item, to: place)
            }
        }
        guard side != turnSide else { return }
        withAnimation(.easeOut(duration: 0.2)) { turnSide = side }
        if let side {
            turner.start { turn(side) }
        } else {
            turner.stop()
        }
    }

    /// Lets go of the app. It glides into its place at `slot`, or, when its place isn't on the
    /// page showing, is simply there.
    func putDown(settlingAt slot: CGPoint?) {
        guard let item = movingItem else { return }
        FolderDrag.log.notice("put down \(item.path, privacy: .public) at \(self.order.firstIndex(of: item) ?? -1)")
        turner.stop()
        withAnimation(.easeOut(duration: 0.2)) { turnSide = nil }
        guard let slot else { return settle() }
        isSettling = true
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            tile.center = slot
            tile.isLifted = false
        }
        let move = moves
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.moves == move else { return }
            self.settle()
        }
    }

    /// Ends the move at once: the app is back among the others.
    private func settle() {
        moves += 1
        isSettling = false
        turner.stop()
        guard item != nil else { return }
        item = nil
        order = []
        turnSide = nil
    }
}

/// Where the app being moved is drawn, in the folder's coordinates.
@MainActor
final class MovingTile: ObservableObject {
    @Published var center = CGPoint.zero
    /// Raised off the folder while it moves; down again as it settles into its place.
    @Published var isLifted = false
}

/// The app being moved, under the pointer and raised a little off the folder.
struct MovingApp: View {
    @ObservedObject var tile: MovingTile
    let icon: NSImage
    let name: String
    @State private var hasAppeared = false

    var body: some View {
        let lifted = tile.isLifted && hasAppeared
        AppTile(icon: icon, name: name, showsName: !lifted)
            .scaleEffect(lifted ? 1.1 : 1)
            .shadow(color: .black.opacity(lifted ? 0.3 : 0), radius: 12, y: 6)
            .position(tile.center)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hasAppeared = true }
            }
    }
}

/// A soft, brighter arc at the side of the folder an app is held at: keep holding it there and
/// the page turns. It brightens while the page is about to turn.
struct PageTurnGlow: View {
    /// -1 for the left side, 1 for the right, nil for neither.
    let side: Int?

    var body: some View {
        GeometryReader { proxy in
            if let side {
                // Centred on the apps, between the folder's name and its bottom edge.
                let middle = (FolderLayout.appsOrigin.y + proxy.size.height - FolderLayout.padding) / 2
                Arc()
                    .frame(width: 104, height: proxy.size.height * 0.8)
                    .position(x: side < 0 ? 0 : proxy.size.width, y: middle)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }

    private struct Arc: View {
        @State private var isCharged = false

        var body: some View {
            Ellipse()
                .fill(EllipticalGradient(colors: [Color.white.opacity(0.5), Color.white.opacity(0)]))
                .opacity(isCharged ? 1 : 0.55)
                .onAppear {
                    withAnimation(.easeIn(duration: PageTurner.firstDelay)) { isCharged = true }
                }
        }
    }
}

/// Turns the page after a moment, then again every so often, until stopped.
@MainActor
final class PageTurner: NSObject {
    static let firstDelay: TimeInterval = 0.6
    private var turn: (() -> Void)?

    func start(_ turn: @escaping () -> Void) {
        self.turn = turn
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        // In every run loop mode, so it also fires while the mouse is held down.
        perform(#selector(fire), with: nil, afterDelay: Self.firstDelay, inModes: [.common])
    }

    func stop() {
        turn = nil
        NSObject.cancelPreviousPerformRequests(withTarget: self)
    }

    @objc private func fire() {
        guard let turn else { return }
        turn()
        perform(#selector(fire), with: nil, afterDelay: 0.9, inModes: [.common])
    }
}
