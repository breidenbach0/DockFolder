import SwiftUI

/// Name, colour and apps for a new folder, with its Dock icon drawn live as you choose.
struct NewFolderSheet: View {
    @ObservedObject var library: FolderLibrary
    let onCreated: (ManagedFolder) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isNameFocused: Bool
    @State private var name = ""
    @State private var tint = FolderTint.clear
    @State private var apps: [URL]
    @State private var keepInDock = true
    @State private var isCreating = false
    @State private var isDropTargeted = false
    @State private var errorMessage: String?

    init(library: FolderLibrary, initialApps: [URL], onCreated: @escaping (ManagedFolder) -> Void) {
        self.library = library
        self.onCreated = onCreated
        _apps = State(initialValue: initialApps)
    }

    var body: some View {
        let nameProblem = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : library.problem(withName: name)

        VStack(spacing: 18) {
            Image(nsImage: FolderIcon.make(from: apps.prefix(9).map { NSWorkspace.shared.icon(forFile: $0.path) },
                                           tint: tint, dark: colorScheme == .dark, size: 256))
                .resizable()
                .frame(width: 104, height: 104)

            VStack(spacing: 4) {
                Text("New Folder")
                    .font(.title2.weight(.semibold))
                Text("It gets its own icon in the Dock.")
                    .foregroundStyle(.secondary)
            }

            card {
                SettingsRow("Name") {
                    TextField("Name", text: $name, prompt: Text("Folder name"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 230)
                        .focused($isNameFocused)
                        .onSubmit(create)
                }
                Divider()
                SettingsRow("Colour") {
                    TintPicker(selection: $tint)
                }
                Divider()
                SettingsRow("Keep in Dock", detail: "The Dock restarts briefly to add it.") {
                    Toggle("Keep in Dock", isOn: $keepInDock)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            appsCard

            if let message = errorMessage ?? nameProblem {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Making the folder…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Folder", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || nameProblem != nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
        .task { isNameFocused = true }
    }

    private var appsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Apps")
                    .font(.headline)
                Spacer()
                Button("Choose Apps…") {
                    let picked = AppPicker.chooseApps(title: "Choose Apps for the Folder", prompt: "Choose")
                    add(picked)
                }
            }
            .padding(.leading, 4)

            Group {
                if apps.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 22, weight: .light))
                        Text("Drop apps here, or choose them. You can also add them later.")
                            .font(.callout)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 92)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 68, maximum: 76), spacing: 6)], spacing: 10) {
                        ForEach(apps, id: \.self) { app in
                            AppChip(url: app) { apps.removeAll { $0 == app } }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isDropTargeted ? Color.accentColor : Color.primary.opacity(0.07),
                                  lineWidth: isDropTargeted ? 2 : 1)
            )
            .dropDestination(for: URL.self) { urls, _ in
                add(urls)
                return true
            } isTargeted: { isDropTargeted = $0 }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(spacing: 0, content: content)
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
            .background(shape.fill(Color.primary.opacity(0.045)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07)))
    }

    private func add(_ urls: [URL]) {
        for url in urls where url.pathExtension == "app" {
            let path = url.standardizedFileURL.path
            if !apps.contains(where: { $0.standardizedFileURL.path == path }) {
                apps.append(url)
            }
        }
    }

    private func create() {
        guard !isCreating, library.problem(withName: name) == nil else { return }
        isCreating = true
        errorMessage = nil
        Task {
            do {
                let folder = try await library.createFolder(named: name, tint: tint, apps: apps, keepInDock: keepInDock)
                onCreated(folder)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}

/// An app picked for the new folder, with a remove button on hover.
private struct AppChip: View {
    let url: URL
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        let name = FileManager.default.displayName(atPath: url.path)
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
            Text(name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: 68)
        .overlay(alignment: .topLeading) {
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(nsColor: .systemGray))
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .offset(x: 4, y: -4)
            .help("Remove \(name)")
        }
        .onHover { isHovered = $0 }
        .help(name)
    }
}
