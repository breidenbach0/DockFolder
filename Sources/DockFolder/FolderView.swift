import SwiftUI

/// Fixed sizes, so the window can be sized up front without measuring SwiftUI.
enum FolderLayout {
    static let iconSize: CGFloat = 64
    static let cellSize = CGSize(width: 88, height: 94)
    static let spacing: CGFloat = 6
    static let padding: CGFloat = 18
    static let headerHeight: CGFloat = 42
    static let pageDotsHeight: CGFloat = 26
    static let cornerRadius: CGFloat = 30

    /// Where the apps start, from the top left of the folder.
    static let appsOrigin = CGPoint(x: padding, y: padding + headerHeight)
    /// How near either side of the apps an app being moved has to be held to turn the page.
    static let pageTurnReach: CGFloat = 24

    /// Pages hold 3 × 3 apps each, like a folder on iPhone.
    static let appsPerPage = 9
    static let maxPages = 3
    /// The grid grows to 6 columns, then to 6 rows.
    static let maxGridColumns = 6
    static let maxGridRows = 6

    static func columns(for count: Int, style: FolderStyle) -> Int {
        switch style {
        case .pages: return 3
        case .grid: return min(maxGridColumns, max(3, count))
        }
    }

    static func rows(for count: Int, style: FolderStyle) -> Int {
        let perRow = columns(for: count, style: style)
        return max(1, (count + perRow - 1) / perRow)
    }

    static func pageCount(for count: Int) -> Int {
        max(1, (count + appsPerPage - 1) / appsPerPage)
    }

    /// The page showing: `page`, unless the folder has since lost pages.
    static func clampedPage(_ page: Int, count: Int) -> Int {
        min(max(page, 0), pageCount(for: count) - 1)
    }

    /// Rows on screen at once. A folder with more than one page always shows a full 3 × 3 page,
    /// so it keeps its size as you turn the pages.
    static func visibleRows(for count: Int, style: FolderStyle) -> Int {
        switch style {
        case .pages: return pageCount(for: count) > 1 ? 3 : rows(for: count, style: .pages)
        case .grid: return min(rows(for: count, style: .grid), maxGridRows)
        }
    }

    /// Only a folder from before there were limits can outgrow a 6 × 6 grid; it scrolls.
    static func scrolls(count: Int, style: FolderStyle) -> Bool {
        style == .grid && rows(for: count, style: .grid) > maxGridRows
    }

    /// The cell under a point in a grid of `columns`, counted from the top left, or nil if the
    /// point is left of, above or beside the cells.
    static func cell(at point: CGPoint, columns: Int) -> Int? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let column = Int(point.x / (cellSize.width + spacing))
        let row = Int(point.y / (cellSize.height + spacing))
        guard column < columns else { return nil }
        return row * columns + column
    }

    /// The app under a point, measured from the top left of the apps on the page showing, or nil.
    static func app(at point: CGPoint, page: Int, count: Int, style: FolderStyle) -> Int? {
        guard point.y < gridSize(itemCount: count, style: style).height,
              let cell = cell(at: point, columns: columns(for: count, style: style)) else { return nil }
        let index = style == .pages ? page * appsPerPage + cell : cell
        return index < count ? index : nil
    }

    /// Where an app being moved goes for a pointer at `point`, measured the same way: the place
    /// under it, or the nearest one when the pointer is beside or below the apps. Nil above them.
    static func place(at point: CGPoint, page: Int, count: Int, style: FolderStyle) -> Int? {
        guard point.y >= 0 else { return nil }
        let grid = gridSize(itemCount: count, style: style)
        let inside = CGPoint(x: min(max(point.x, 0), grid.width - 1), y: min(point.y, grid.height - 1))
        guard let cell = cell(at: inside, columns: columns(for: count, style: style)) else { return nil }
        return min(style == .pages ? page * appsPerPage + cell : cell, count - 1)
    }

    /// The side an app being moved is held at to turn the page, measured the same way: -1 for
    /// the left, 1 for the right. Nil away from the sides, or with no page that way.
    static func pageTurn(at point: CGPoint, page: Int, count: Int, style: FolderStyle) -> Int? {
        guard style == .pages else { return nil }
        let grid = gridSize(itemCount: count, style: style)
        guard point.y > -pageTurnReach, point.y < grid.height + pageDotsHeight else { return nil }
        if point.x < pageTurnReach, page > 0 { return -1 }
        if point.x > grid.width - pageTurnReach, page < pageCount(for: count) - 1 { return 1 }
        return nil
    }

    /// The centre of the app at `index`, measured from the top left of the apps on its page.
    static func center(of index: Int, count: Int, style: FolderStyle) -> CGPoint {
        let columns = columns(for: count, style: style)
        let cell = style == .pages ? index % appsPerPage : index
        return CGPoint(x: CGFloat(cell % columns) * (cellSize.width + spacing) + cellSize.width / 2,
                       y: CGFloat(cell / columns) * (cellSize.height + spacing) + cellSize.height / 2)
    }

    static func showsPageDots(for count: Int, style: FolderStyle) -> Bool {
        style == .pages && pageCount(for: count) > 1
    }

    static func gridSize(itemCount: Int, style: FolderStyle) -> CGSize {
        let cols = CGFloat(columns(for: itemCount, style: style))
        let rows = CGFloat(visibleRows(for: itemCount, style: style))
        return CGSize(width: cols * cellSize.width + (cols - 1) * spacing,
                      height: rows * cellSize.height + (rows - 1) * spacing)
    }

    static func panelSize(itemCount: Int, style: FolderStyle) -> CGSize {
        let grid = gridSize(itemCount: itemCount, style: style)
        let dots = showsPageDots(for: itemCount, style: style) ? pageDotsHeight : 0
        return CGSize(width: grid.width + padding * 2,
                      height: grid.height + dots + headerHeight + padding * 2)
    }
}

/// The open folder: its name, a + button and the grid of apps, on Liquid Glass.
/// Used both for the panel above the Dock icon and for the preview in the DockFolder window.
struct FolderView: View {
    @ObservedObject var store: FolderStore
    /// False when the window around the view provides the background (before macOS 26).
    var drawsGlass = true
    /// The arrow keys turn the pages. Only for the panel above the Dock, which has no other use
    /// for them; while an app is being moved, they turn the pages anywhere.
    var arrowKeysTurnPages = false
    /// Moves an app dragged from the Dock under the folder into it. Only in the DockFolder window.
    var onDockApp: ((URL) -> Bool)? = nil
    /// Lights the drop outline for an app held over the folder from the real Dock, whose drags
    /// SwiftUI never sees (see DockDragWatcher).
    var showsDropTarget = false
    let onOpen: (FolderItem) -> Void
    let onAdd: () -> Void
    @State private var isDropTargeted = false
    /// The page showing, with pages.
    @State private var page = 0
    @StateObject private var rearrangement = Rearrangement()
    /// Set while the mouse is down moving an app. SwiftUI clears it if the move is cancelled too.
    @GestureState private var isMovingApp = false

    /// The folder's coordinates, from the top left of its glass.
    private static let space = "folder"

    var body: some View {
        let moving = rearrangement.item
        // While an app is being moved, the order it's moving through. Saved when it's let go.
        let items = moving == nil ? store.items : rearrangement.order
        let grid = FolderLayout.gridSize(itemCount: items.count, style: store.style)
        let shape = RoundedRectangle(cornerRadius: FolderLayout.cornerRadius, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            header
            if items.isEmpty {
                emptyState
                    .frame(width: grid.width, height: grid.height)
            } else if store.style == .pages {
                FolderPages(store: store, items: items, page: $page, moving: moving,
                            arrowKeysTurnPages: arrowKeysTurnPages || moving != nil, onOpen: onOpen)
                    .simultaneousGesture(moveGesture)
            } else {
                FolderGrid(store: store, items: items, moving: moving, onOpen: onOpen)
                    .simultaneousGesture(moveGesture)
            }
        }
        .padding(FolderLayout.padding)
        .coordinateSpace(name: Self.space)
        .background {
            PageTurnGlow(side: rearrangement.turnSide)
                .clipShape(shape)
        }
        .overlay {
            if let moving {
                MovingApp(tile: rearrangement.tile, icon: store.icon(for: moving),
                          name: store.displayName(for: moving))
                    .id(moving.id)
            }
        }
        .modifier(FolderGlass(enabled: drawsGlass, shape: shape, tint: store.tint.glassColor))
        .overlay {
            shape.strokeBorder(Color.accentColor, lineWidth: 3)
                .opacity(isDropTargeted || showsDropTarget ? 1 : 0)
        }
        .onDrop(of: FolderDrag.dropTypes, delegate: FolderDropDelegate(
            store: store, isTargeted: $isDropTargeted, onDockApp: onDockApp))
        .animation(.easeOut(duration: 0.15), value: isDropTargeted || showsDropTarget)
        // The page turned while an app is being moved (held at a side, ← →, a swipe): it comes along.
        .onChange(of: page) { _ in
            if rearrangement.movingItem != nil { follow(rearrangement.pointer) }
        }
        .onChange(of: isMovingApp) { isMoving in
            if !isMoving { putDown() }
        }
    }

    /// Press on an app and move the pointer to carry it somewhere else in the folder: it follows
    /// the pointer, the other apps make room, and it stays where it's let go.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .updating($isMovingApp) { _, isMoving, _ in isMoving = true }
            .onChanged { value in
                if rearrangement.movingItem == nil, !pickUp(at: value.startLocation) { return }
                follow(value.location)
            }
            .onEnded { _ in putDown() }
    }

    /// Picks up the app the press began on. False if it began beside the apps.
    private func pickUp(at start: CGPoint) -> Bool {
        let items = store.items
        guard !FolderLayout.scrolls(count: items.count, style: store.style) else { return false }
        let origin = FolderLayout.appsOrigin
        let current = FolderLayout.clampedPage(page, count: items.count)
        guard let index = FolderLayout.app(at: CGPoint(x: start.x - origin.x, y: start.y - origin.y),
                                           page: current, count: items.count, style: store.style) else { return false }
        let center = FolderLayout.center(of: index, count: items.count, style: store.style)
        rearrangement.pickUp(items[index], from: items, at: start,
                             center: CGPoint(x: origin.x + center.x, y: origin.y + center.y))
        return true
    }

    /// Carries the app being moved to the place under the pointer, and turns the page while
    /// it's held at a side.
    private func follow(_ pointer: CGPoint) {
        let count = rearrangement.order.count
        let current = FolderLayout.clampedPage(page, count: count)
        let point = CGPoint(x: pointer.x - FolderLayout.appsOrigin.x, y: pointer.y - FolderLayout.appsOrigin.y)
        rearrangement.follow(pointer,
                             to: FolderLayout.place(at: point, page: current, count: count, style: store.style),
                             turning: FolderLayout.pageTurn(at: point, page: current, count: count, style: store.style),
                             turn: turnPage(by:))
    }

    private func turnPage(by step: Int) {
        let count = rearrangement.order.count
        let target = FolderLayout.clampedPage(FolderLayout.clampedPage(page, count: count) + step, count: count)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { page = target }
    }

    /// Puts the app being moved down in its new place, and saves the folder's new order.
    private func putDown() {
        guard let item = rearrangement.movingItem else { return }
        let order = rearrangement.order
        let index = order.firstIndex(of: item) ?? 0
        store.move(item, to: index)
        // It glides into its place, if that's on the page showing.
        var slot: CGPoint?
        if store.style == .grid || index / FolderLayout.appsPerPage == FolderLayout.clampedPage(page, count: order.count) {
            let center = FolderLayout.center(of: index, count: order.count, style: store.style)
            slot = CGPoint(x: FolderLayout.appsOrigin.x + center.x, y: FolderLayout.appsOrigin.y + center.y)
        }
        rearrangement.putDown(settlingAt: slot)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(store.name)
                .font(.system(size: 20, weight: .bold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(CircleIconButtonStyle())
            .disabled(store.isFull)
            .help(store.isFull ? "This folder is full" : "Add apps")
        }
        .frame(height: FolderLayout.headerHeight, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus.square.dashed")
                .font(.system(size: 26, weight: .light))
            Text("Drag apps here from the Dock or the Finder, or click +")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: FolderLayout.cellSize.height)
    }
}

/// All the apps on one page, up to 6 × 6.
private struct FolderGrid: View {
    @ObservedObject var store: FolderStore
    /// The apps in the order shown: the folder's, or the order an app is being moved through.
    let items: [FolderItem]
    let moving: FolderItem?
    let onOpen: (FolderItem) -> Void

    var body: some View {
        let count = items.count
        let grid = FolderLayout.gridSize(itemCount: count, style: .grid)
        let scrolls = FolderLayout.scrolls(count: count, style: .grid)

        ScrollView {
            AppGrid(items: items, columns: FolderLayout.columns(for: count, style: .grid),
                    store: store, moving: moving, onOpen: onOpen)
        }
        .scrollIndicators(scrolls ? .automatic : .never)
        .scrollDisabled(!scrolls)
        .frame(width: grid.width, height: grid.height)
    }
}

/// Apps in rows of `columns`, from the top left.
struct AppGrid: View {
    let items: [FolderItem]
    let columns: Int
    let store: FolderStore
    /// The app being moved. Its cell stays empty: the gap it goes in when it's let go.
    let moving: FolderItem?
    let onOpen: (FolderItem) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(FolderLayout.cellSize.width), spacing: FolderLayout.spacing),
                                 count: columns),
                  alignment: .leading, spacing: FolderLayout.spacing) {
            ForEach(items) { item in
                FolderCell(item: item, store: store, isGap: item.id == moving?.id,
                           isRearranging: moving != nil, onOpen: onOpen)
            }
        }
    }
}

private struct FolderGlass<S: Shape>: ViewModifier {
    let enabled: Bool
    let shape: S
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.glassBackground(in: shape, tint: tint)
        } else {
            content
        }
    }
}

struct FolderCell: View {
    let item: FolderItem
    let store: FolderStore
    /// This app is being moved, so its cell is an empty gap.
    var isGap = false
    /// An app is being moved: no hover highlight, and no opening apps, meanwhile.
    var isRearranging = false
    let onOpen: (FolderItem) -> Void
    @State private var isHovered = false

    var body: some View {
        let url = store.url(for: item)
        let missing = url == nil
        let name = store.displayName(for: item, at: url)
        let highlight = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let hovered = isHovered && !isRearranging

        AppTile(icon: store.icon(for: item, at: url), name: name, iconScale: hovered ? 1.06 : 1)
            .background(highlight.fill(Color.primary.opacity(hovered ? 0.08 : 0)))
            .contentShape(highlight)
            .opacity(isGap ? 0 : missing ? 0.4 : 1)
            // A click opens the app. Pressing and moving the pointer moves it (see FolderView).
            .onTapGesture {
                if !isRearranging { onOpen(item) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen(item) }
            .onHover { hovering in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { isHovered = hovering }
            }
            .help(missing ? "Can’t find \(item.path)" : name)
            .contextMenu {
                Button("Open") { onOpen(item) }
                Button("Show in Finder") { store.revealInFinder(item) }
                    .disabled(missing)
                Divider()
                Button("Move Left") { store.move(item, by: -1) }
                Button("Move Right") { store.move(item, by: 1) }
                Divider()
                Button("Remove from Folder", role: .destructive) { store.remove(item) }
            }
    }
}

/// An app's icon with its name underneath, the size of a cell.
struct AppTile: View {
    let icon: NSImage
    let name: String
    var showsName = true
    var iconScale: CGFloat = 1

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: FolderLayout.iconSize, height: FolderLayout.iconSize)
                .scaleEffect(iconScale)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 4)
                .opacity(showsName ? 1 : 0)
        }
        .frame(width: FolderLayout.cellSize.width, height: FolderLayout.cellSize.height)
    }
}
