import SwiftUI

/// One folder: a live preview of it on glass, then its colour, Dock and file settings.
struct FolderDetailView: View {
    @ObservedObject var folder: ManagedFolder
    @ObservedObject var store: FolderStore
    @ObservedObject var library: FolderLibrary
    let onRename: () -> Void
    @State private var isConfirmingDelete = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var fullMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if folder.isOutdated { updateBanner }

                FolderStage(store: store, onAdd: addApps)

                SettingsSection("Colour") {
                    SettingsRow("Glass tint", detail: "Tints the open folder and its Dock icon.") {
                        TintPicker(selection: Binding(get: { store.tint }, set: { store.setTint($0) }))
                    }
                }

                SettingsSection("Layout") {
                    SettingsRow("\(store.items.count) of \(store.capacity) apps",
                                detail: store.style == .pages
                                    ? "Swipe with two fingers, click the dots or use the arrow keys to turn the page."
                                    : "Every app on one page.") {
                        StylePicker(selection: Binding(get: { store.style }, set: { store.setStyle($0) }),
                                    appCount: store.items.count)
                    }
                }

                SettingsSection("Dock") {
                    SettingsRow("Keep in Dock", detail: "The Dock restarts briefly to pick up the change.") {
                        Toggle("Keep in Dock", isOn: Binding(
                            get: { folder.isInDock },
                            set: { library.setKeepInDock($0, for: folder) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    Divider()
                    SettingsRow(folder.isRunning ? "Running" : "Not running",
                                detail: folder.isRunning
                                    ? "Its Dock icon shows the apps inside and opens the folder."
                                    : "Start it so its Dock icon shows the apps inside and opens the folder.") {
                        if !folder.isRunning {
                            Button("Start") { library.launch(folder) }
                        }
                    }
                }

                SettingsSection("Folder") {
                    SettingsRow("Name", detail: folder.name) {
                        Button("Rename…", action: onRename)
                            .disabled(isWorking)
                    }
                    Divider()
                    SettingsRow("Location", detail: folder.url.deletingLastPathComponent().path) {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([folder.url])
                        }
                    }
                    Divider()
                    SettingsRow("Delete Folder", detail: "Moves the folder to the Trash. The apps inside it aren’t touched.") {
                        Button("Delete…", role: .destructive) { isConfirmingDelete = true }
                            .disabled(isWorking)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(folder.name)
        .navigationSubtitle(store.items.count == 1 ? "1 app" : "\(store.items.count) apps")
        .toolbar {
            ToolbarItem {
                Button(action: addApps) {
                    Label("Add Apps", systemImage: "plus.app")
                }
                .help("Add apps to \(folder.name)")
            }
        }
        .confirmationDialog("Delete “\(folder.name)”?", isPresented: $isConfirmingDelete) {
            Button("Move to Trash", role: .destructive) { run { try await library.delete(folder) } }
        } message: {
            Text("The folder leaves the Dock and goes to the Trash. The apps inside it aren’t affected.")
        }
        .alert("This Folder Is Full", isPresented: Binding(
            get: { fullMessage != nil },
            set: { if !$0 { fullMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(fullMessage ?? "")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var updateBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Made with another version of DockFolder")
                    .font(.headline)
                Text("Update it to get this version’s look. Its apps and its place in the Dock stay as they are.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(isWorking ? "Updating…" : "Update") {
                run { try await library.update(folder) }
            }
            .glassButtonStyle(prominent: true)
            .disabled(isWorking)
        }
        .padding(16)
        .glassBackground(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func addApps() {
        let left = store.add(AppPicker.chooseApps(title: "Add to \(folder.name)"))
        guard left > 0 else { return }
        let apps = left == 1 ? "1 app wasn’t" : "\(left) apps weren’t"
        fullMessage = store.style == .pages
            ? "“\(folder.name)” holds up to \(FolderStyle.pages.capacity) apps on 3 pages, so \(apps) added. Switch its layout to the grid to fit up to \(FolderStyle.grid.capacity)."
            : "“\(folder.name)” holds up to \(FolderStyle.grid.capacity) apps, so \(apps) added."
    }

    private func run(_ work: @escaping () async throws -> Void) {
        isWorking = true
        Task {
            do {
                try await work()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// The folder as it looks above the Dock: its glass panel over the desktop picture,
/// with its Dock icon underneath on a slice of glass Dock.
struct FolderStage: View {
    @ObservedObject var store: FolderStore
    let onAdd: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let panel = FolderLayout.panelSize(itemCount: store.items.count, style: store.style)
        let stage = RoundedRectangle(cornerRadius: 24, style: .continuous)

        VStack(spacing: 14) {
            FolderView(store: store, onOpen: { store.open($0) }, onAdd: onAdd)
                .frame(width: panel.width, height: panel.height)
            Image(nsImage: FolderIcon.make(from: store.previewIcons(), tint: store.tint,
                                           dark: colorScheme == .dark, size: 128))
                .resizable()
                .frame(width: 58, height: 58)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .glassBackground(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .help("The folder’s Dock icon")
        }
        .padding(.top, 36)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background { DesktopBackdrop() }
        .clipShape(stage)
        .overlay(stage.strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// The desktop picture, so the glass looks as it will over the desktop. A soft gradient when
/// the picture can't be read, such as a moving wallpaper.
struct DesktopBackdrop: View {
    var body: some View {
        if let image = DesktopPicture.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(colors: [Color(red: 0.32, green: 0.52, blue: 0.95),
                                    Color(red: 0.62, green: 0.4, blue: 0.86),
                                    Color(red: 0.98, green: 0.62, blue: 0.48)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

@MainActor
enum DesktopPicture {
    /// Read once, at a size that's plenty for a preview.
    static let image: NSImage? = {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              // Pictures in the home folder (Pictures, Desktop…) would trigger a privacy prompt.
              !url.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1800,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }()
}

/// A titled group of rows on a rounded card, in the style of System Settings.
struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let card = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
                .background(card.fill(Color.primary.opacity(0.045)))
                .overlay(card.strokeBorder(Color.primary.opacity(0.07)))
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    let detail: String?
    let accessory: Accessory

    init(_ title: String, detail: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.vertical, 11)
    }
}
