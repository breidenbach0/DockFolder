import AppKit
import Combine
import UniformTypeIdentifiers

/// One binary, two jobs. DockFolder.app itself opens the window for making and changing folders;
/// every folder is a copy of it whose Info.plist has no role, and runs as that folder.
enum AppRole {
    case manager, folder

    static let infoKey = "DockFolderRole"

    static var current: AppRole {
        // `-DockFolderRole manager` on the command line also works, for running from Xcode.
        let role = UserDefaults.standard.string(forKey: infoKey)
            ?? Bundle.main.object(forInfoDictionaryKey: infoKey) as? String
        return role == "manager" ? .manager : .folder
    }
}

@main
enum DockFolderMain {
    @MainActor
    static func main() {
        // scripts/build-app.sh draws the app icon with this.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--write-iconset"), arguments.indices.contains(index + 1) {
            do {
                try FolderIcon.writeAppIconset(to: URL(fileURLWithPath: arguments[index + 1]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Couldn't write the icon: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }

        switch AppRole.current {
        case .manager:
            ManagerApp.main()
        case .folder:
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            // `app.delegate` is weak, so keep the delegate alive for as long as the app runs.
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
    }
}

/// One running copy of this app is one folder in the Dock.
/// Its Dock icon is the folder; clicking the icon opens the grid just above it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Also write the folder icon into the .app bundle, so the Dock keeps showing it
    /// after the app quits. Set to false if you'd rather never touch the bundle.
    static let persistIconToBundle = true

    private var store: FolderStore!
    private var panel: PanelController!
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    private var lastPersistedIcon: PersistedIcon?

    /// What the icon written into the bundle shows, so it's only rewritten when that changes.
    private struct PersistedIcon: Equatable {
        var items: [UUID]
        var tint: FolderTint
        var dark: Bool
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set up here rather than in didFinishLaunching: apps dropped onto the Dock icon
        // while we're not running arrive via application(_:open:) before didFinishLaunching.
        store = FolderStore()
        panel = PanelController(store: store)
        panel.onAddApps = { [weak self] in self?.addApps() }
        NSApp.mainMenu = makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apps or colour changed here, or in the DockFolder window.
        Publishers.CombineLatest(store.$items, store.$tint)
            .sink { [weak self] _, _ in self?.refreshDockIcon() }
            .store(in: &cancellables)
        // Light or dark glass, to match the Dock.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshDockIcon() }
        }

        // Launched by a click on our Dock icon: open right away. Launched at login: stay quiet.
        if !panel.isOpen, DockGeometry.isOverDock(NSEvent.mouseLocation) {
            panel.show()
        }
    }

    /// The user clicked our Dock icon while we're running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.toggle()
        return false
    }

    /// Apps dragged onto our Dock icon (Info.plist declares that we accept app bundles).
    func application(_ application: NSApplication, open urls: [URL]) {
        store.add(urls)
        panel.show()
    }

    /// Extra items in the Dock icon's right-click menu (macOS adds Options, Quit, etc.).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(menuItem("Add Apps…", #selector(addAppsFromMenu)))
        menu.addItem(menuItem("Show Folder Data in Finder", #selector(revealData)))
        return menu
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Actions

    @objc private func addAppsFromMenu() { addApps() }

    @objc private func revealData() {
        let exists = FileManager.default.fileExists(atPath: store.dataURL.path)
        let target = exists ? store.dataURL : store.dataURL.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func addApps() {
        // Reopen where the folder was, not wherever the pointer ends up after the picker.
        let anchor = panel.isOpen ? panel.anchor : NSEvent.mouseLocation
        panel.close(hideApp: false, animated: false)
        let urls = AppPicker.chooseApps(title: "Add to \(store.name)")
        guard !urls.isEmpty else { return }
        store.add(urls)
        panel.show(near: anchor)
    }

    // MARK: - Dock icon

    private func refreshDockIcon() {
        let dark = NSApp.effectiveAppearance.isDark
        let image = FolderIcon.make(from: store.previewIcons(), tint: store.tint, dark: dark)
        NSApp.applicationIconImage = image   // live icon while we're running

        let shown = PersistedIcon(items: store.items.prefix(9).map(\.id), tint: store.tint, dark: dark)
        guard Self.persistIconToBundle,
              shown != lastPersistedIcon,
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        lastPersistedIcon = shown
        // Custom Finder icon on our own bundle, so the Dock shows it while we're not running.
        _ = NSWorkspace.shared.setIcon(image, forFile: Bundle.main.bundlePath, options: [])
    }

    // MARK: - Menus

    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(menuItem("Add Apps…", #selector(addAppsFromMenu), key: "o"))
        appMenu.addItem(menuItem("Show Folder Data in Finder", #selector(revealData)))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(store.name)",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        return mainMenu
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}

enum AppPicker {
    /// Asks for one or more apps, starting in /Applications. Empty if cancelled.
    @MainActor
    static func chooseApps(title: String, prompt: String = "Add") -> [URL] {
        let picker = NSOpenPanel()
        picker.title = title
        picker.prompt = prompt
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.allowedContentTypes = [.application]
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        NSApp.activate(ignoringOtherApps: true)
        return picker.runModal() == .OK ? picker.urls : []
    }
}
