import SwiftUI

/// A new name for a folder. The folder keeps its apps, colour and place in the Dock.
struct RenameFolderSheet: View {
    @ObservedObject var folder: ManagedFolder
    @ObservedObject var library: FolderLibrary

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isNameFocused: Bool
    @State private var name: String
    @State private var isRenaming = false
    @State private var errorMessage: String?

    init(folder: ManagedFolder, library: FolderLibrary) {
        self.folder = folder
        self.library = library
        _name = State(initialValue: folder.name)
    }

    var body: some View {
        let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unchanged = newName == folder.name
        let problem = newName.isEmpty || unchanged ? nil : library.problem(renaming: folder, to: newName)

        VStack(spacing: 16) {
            Image(nsImage: FolderIcon.make(from: folder.store.previewIcons(), tint: folder.store.tint,
                                           dark: colorScheme == .dark, size: 192))
                .resizable()
                .frame(width: 76, height: 76)

            Text("Rename “\(folder.name)”")
                .font(.title3.weight(.semibold))

            TextField("Name", text: $name, prompt: Text("Folder name"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .focused($isNameFocused)
                .onSubmit(rename)

            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            if let message = errorMessage ?? problem {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                if isRenaming {
                    ProgressView()
                        .controlSize(.small)
                    Text("Renaming…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRenaming || newName.isEmpty || unchanged || problem != nil)
            }
        }
        .padding(24)
        .frame(width: 380)
        .task { isNameFocused = true }
    }

    private var note: String {
        if folder.isInDock {
            return "The folder restarts, and the Dock restarts briefly to show the new name."
        }
        if folder.isRunning {
            return "The folder restarts under its new name."
        }
        return "Its apps and colour stay the same."
    }

    private func rename() {
        let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRenaming, newName != folder.name, library.problem(renaming: folder, to: newName) == nil else { return }
        isRenaming = true
        errorMessage = nil
        Task {
            do {
                try await library.rename(folder, to: newName)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isRenaming = false
            }
        }
    }
}
