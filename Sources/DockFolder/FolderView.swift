import SwiftUI

/// Fixed sizes, so the window can be sized up front without measuring SwiftUI.
enum FolderLayout {
    static let iconSize: CGFloat = 64
    static let cellSize = CGSize(width: 88, height: 94)
    static let spacing: CGFloat = 6
    static let padding: CGFloat = 18
    static let headerHeight: CGFloat = 42
    static let cornerRadius: CGFloat = 30
    static let maxVisibleRows = 4

    /// iPhone-style 3 columns; 4 once a folder outgrows a 3×3 grid.
    static func columns(for count: Int) -> Int {
        count <= 9 ? 3 : 4
    }

    static func rows(for count: Int) -> Int {
        let perRow = columns(for: count)
        return max(1, (count + perRow - 1) / perRow)
    }

    static func gridSize(itemCount: Int) -> CGSize {
        let cols = CGFloat(columns(for: itemCount))
        let visibleRows = CGFloat(min(rows(for: itemCount), maxVisibleRows))
        return CGSize(width: cols * cellSize.width + (cols - 1) * spacing,
                      height: visibleRows * cellSize.height + (visibleRows - 1) * spacing)
    }

    static func panelSize(itemCount: Int) -> CGSize {
        let grid = gridSize(itemCount: itemCount)
        return CGSize(width: grid.width + padding * 2,
                      height: grid.height + headerHeight + padding * 2)
    }
}

/// The open folder: its name, a + button and the grid of apps, on Liquid Glass.
/// Used both for the panel above the Dock icon and for the preview in the DockFolder window.
struct FolderView: View {
    @ObservedObject var store: FolderStore
    /// False when the window around the view provides the background (before macOS 26).
    var drawsGlass = true
    let onOpen: (FolderItem) -> Void
    let onAdd: () -> Void
    @State private var isDropTargeted = false

    var body: some View {
        let count = store.items.count
        let grid = FolderLayout.gridSize(itemCount: count)
        let scrolls = FolderLayout.rows(for: count) > FolderLayout.maxVisibleRows
        let shape = RoundedRectangle(cornerRadius: FolderLayout.cornerRadius, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                if store.items.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: gridColumns(for: count), spacing: FolderLayout.spacing) {
                        ForEach(store.items) { item in
                            FolderCell(item: item, store: store, onOpen: onOpen)
                        }
                    }
                }
            }
            .scrollIndicators(scrolls ? .automatic : .never)
            .scrollDisabled(!scrolls)
            .frame(width: grid.width, height: grid.height)
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
            store.add(apps)
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
            .help("Add apps")
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

    private func gridColumns(for count: Int) -> [GridItem] {
        Array(repeating: GridItem(.fixed(FolderLayout.cellSize.width), spacing: FolderLayout.spacing),
              count: FolderLayout.columns(for: count))
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
