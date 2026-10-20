import SwiftUI

/// The DockFolder window: folders in the sidebar, the selected one on the right.
struct ManagerView: View {
    @ObservedObject var library: FolderLibrary
    @State private var selection: ManagedFolder.ID?
    @State private var renaming: ManagedFolder?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Folders") {
                    ForEach(library.folders) { folder in
                        FolderRow(folder: folder, store: folder.store)
                            .tag(folder.id)
                            .contextMenu {
                                Button("Rename…") { renaming = folder }
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([folder.url])
                                }
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
            .toolbar {
                ToolbarItem {
                    Button {
                        library.requestNewFolder()
                    } label: {
                        Label("New Folder", systemImage: "plus")
                    }
                    .help("New Folder")
                }
            }
        } detail: {
            Group {
                if let folder = library.folder(withID: selection) {
                    FolderDetailView(folder: folder, store: folder.store, library: library) {
                        renaming = folder
                    }
                    .id(folder.id)
                } else {
                    WelcomeView(hasFolders: !library.folders.isEmpty) { library.requestNewFolder() }
                }
            }
            .sheet(item: $renaming) { folder in
                RenameFolderSheet(folder: folder, library: library)
            }
        }
        .frame(minWidth: 800, minHeight: 560)
        .sheet(item: $library.newFolderRequest) { request in
            NewFolderSheet(library: library, initialApps: request.apps) { folder in
                selection = folder.id
            }
        }
        // Keep a folder selected, also after one is deleted.
        .onReceive(library.$folders) { folders in
            if !folders.contains(where: { $0.id == selection }) {
                selection = folders.first?.id
            }
        }
        // Folders made with make-folder.sh, or kept in or taken out of the Dock elsewhere.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.reload()
        }
    }
}

struct FolderRow: View {
    @ObservedObject var folder: ManagedFolder
    @ObservedObject var store: FolderStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FolderIcon.make(from: store.previewIcons(), tint: store.tint,
                                           dark: colorScheme == .dark, size: 96))
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                    .lineLimit(1)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let apps = store.items.count == 1 ? "1 app" : "\(store.items.count) apps"
        if folder.isOutdated { return "\(apps) · Update available" }
        return folder.isInDock ? "\(apps) · In Dock" : apps
    }
}

/// Shown when no folder is selected, and as the first thing anyone sees.
struct WelcomeView: View {
    let hasFolders: Bool
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: FolderIcon.makeAppIcon(size: 256))
                .resizable()
                .frame(width: 128, height: 128)
            Text(hasFolders ? "Select a Folder" : "Make Your First Folder")
                .font(.title2.weight(.semibold))
            Text("A folder keeps a group of apps behind one Dock icon. Click the icon and the apps open in a glass grid above it, like a folder on iPhone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button("New Folder…", action: onCreate)
                .controlSize(.large)
                .glassButtonStyle(prominent: true)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
