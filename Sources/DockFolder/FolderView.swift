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

    /// Rows on screen at once. A folder with more than one page always shows a full 3 × 3 page,
    /// so it keeps its size as you turn the pages.
    static func visibleRows(for count: Int, style: FolderStyle) -> Int {
        switch style {
        case .pages: return pageCount(for: count) > 1 ? 3 : rows(for: count, style: .pages)
        case .grid: return min(rows(for: count, style: .grid), maxGridRows)
        }
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
    /// The arrow keys turn the pages. Only for the panel above the Dock, which has no other use for them.
    var arrowKeysTurnPages = false
    let onOpen: (FolderItem) -> Void
    let onAdd: () -> Void
    @State private var isDropTargeted = false

    var body: some View {
        let grid = FolderLayout.gridSize(itemCount: store.items.count, style: store.style)
        let shape = RoundedRectangle(cornerRadius: FolderLayout.cornerRadius, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            header
            if store.items.isEmpty {
                emptyState
                    .frame(width: grid.width, height: grid.height)
            } else if store.style == .pages {
                FolderPages(store: store, arrowKeysTurnPages: arrowKeysTurnPages, onOpen: onOpen)
            } else {
                FolderGrid(store: store, onOpen: onOpen)
            }
        }
        .padding(FolderLayout.padding)
        .modifier(FolderGlass(enabled: drawsGlass, shape: shape, tint: store.tint.glassColor))
        .overlay {
            shape.strokeBorder(Color.accentColor, lineWidth: 3)
                .opacity(isDropTargeted ? 1 : 0)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let apps = urls.filter { $0.pathExtension == "app" }
            guard !apps.isEmpty else { return false }
            if store.add(apps) > 0 { NSSound.beep() }   // the folder is full
            return true
        } isTargeted: { isDropTargeted = $0 }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
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
            Text("Drop apps here or on the folder’s Dock icon, or click +")
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
    let onOpen: (FolderItem) -> Void

    var body: some View {
        let count = store.items.count
        let grid = FolderLayout.gridSize(itemCount: count, style: .grid)
        // Only a folder from before there were limits can outgrow 6 × 6; it scrolls.
        let scrolls = FolderLayout.rows(for: count, style: .grid) > FolderLayout.maxGridRows

        ScrollView {
            AppGrid(items: store.items, columns: FolderLayout.columns(for: count, style: .grid),
                    store: store, onOpen: onOpen)
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
    let onOpen: (FolderItem) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(FolderLayout.cellSize.width), spacing: FolderLayout.spacing),
                                 count: columns),
                  alignment: .leading, spacing: FolderLayout.spacing) {
            ForEach(items) { item in
                FolderCell(item: item, store: store, onOpen: onOpen)
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
    let onOpen: (FolderItem) -> Void
    @State private var isHovered = false

    var body: some View {
        let missing = store.url(for: item) == nil
        let name = store.displayName(for: item)
        let highlight = RoundedRectangle(cornerRadius: 16, style: .continuous)

        Button { onOpen(item) } label: {
            VStack(spacing: 6) {
                Image(nsImage: store.icon(for: item))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: FolderLayout.iconSize, height: FolderLayout.iconSize)
                    .scaleEffect(isHovered ? 1.06 : 1)
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 4)
            }
            .frame(width: FolderLayout.cellSize.width, height: FolderLayout.cellSize.height)
            .background(highlight.fill(Color.primary.opacity(isHovered ? 0.08 : 0)))
            .contentShape(highlight)
        }
        .buttonStyle(PressableButtonStyle())
        .opacity(missing ? 0.4 : 1)
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
