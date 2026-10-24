import SwiftUI

/// DockFolder.app itself: a window for making, changing and removing folders.
struct ManagerApp: App {
    @NSApplicationDelegateAdaptor(ManagerAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("DockFolder", id: "folders") {
            ManagerView(library: appDelegate.library, updater: appDelegate.updater)
        }
        .defaultSize(width: 940, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Folder…") { appDelegate.library.requestNewFolder() }
                    .keyboardShortcut("n")
            }
            UpdateCommands(updater: appDelegate.updater)
        }
    }
}

@MainActor
final class ManagerAppDelegate: NSObject, NSApplicationDelegate {
    let library = FolderLibrary()
    let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // build-app.sh puts an .icns in the bundle; this covers running without one.
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil {
            NSApp.applicationIconImage = FolderIcon.makeAppIcon()
        }
        // Just updated itself: bring the folders along. Then look for newer versions.
        Task {
            await updater.finishUpdate(library: library)
            updater.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Apps dropped on DockFolder's own icon start a new folder.
    func application(_ application: NSApplication, open urls: [URL]) {
        let apps = urls.filter { $0.pathExtension == "app" }
        guard !apps.isEmpty else { return }
        library.requestNewFolder(with: apps)
    }
}

/// DockFolder › Check for Updates…, and whether to check by itself.
struct UpdateCommands: Commands {
    @ObservedObject var updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Task { await updater.check(userInitiated: true) }
            }
            .disabled(updater.isBusy)
            Toggle("Check for Updates Automatically", isOn: $updater.checksAutomatically)
        }
    }
}
