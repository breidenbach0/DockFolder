import SwiftUI

/// DockFolder.app itself: a window for making, changing and removing folders.
struct ManagerApp: App {
    @NSApplicationDelegateAdaptor(ManagerAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("DockFolder", id: "folders") {
            ManagerView(library: appDelegate.library)
        }
        .defaultSize(width: 940, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Folder…") { appDelegate.library.requestNewFolder() }
                    .keyboardShortcut("n")
            }
        }
    }
}

@MainActor
final class ManagerAppDelegate: NSObject, NSApplicationDelegate {
    let library = FolderLibrary()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // build-app.sh puts an .icns in the bundle; this covers running without one.
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil {
            NSApp.applicationIconImage = FolderIcon.makeAppIcon()
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
