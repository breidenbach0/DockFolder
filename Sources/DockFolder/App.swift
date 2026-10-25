import AppKit
import Combine
import UniformTypeIdentifiers

/// One binary, two jobs. DockFolder.app itself opens the window for making and changing folders;
/// every folder is a copy of it whose Info.plist has no role, and runs as that folder.
enum AppRole {
    case manager, folder

    static let infoKey = "DockFolderRole"

    static var current: AppRole {
        // `-DockFolderRole manager` on the command line also works, for running from Xcode. Only
        // there: a stray `defaults write -g` mustn't turn every folder into the DockFolder window.
        let argument = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[infoKey] as? String
        let role = argument ?? Bundle.main.object(forInfoDictionaryKey: infoKey) as? String
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
    /// What the live Dock icon shows, so it's only redrawn when that changes.
    private var shownIcon: ShownIcon?

    private struct ShownIcon: Equatable {
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
        panel.onClose = { [weak self] in self?.scheduleBundleIcon() }
        NSApp.mainMenu = makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apps or colour changed here, or in the DockFolder window. @Published sends the new
        // values just before the store has them, so the icon is drawn from the values sent.
        Publishers.CombineLatest(store.$items, store.$tint)
            .sink { [weak self] items, tint in self?.refreshDockIcon(items: items, tint: tint) }
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

    /// Apps dragged onto our Dock icon (Info.plist declares that we accept app bundles). Anything
    /// else sent our way, by `open -a` say, is ignored.
    func application(_ application: NSApplication, open urls: [URL]) {
        let apps = urls.filter { $0.pathExtension == "app" }
        guard !apps.isEmpty else { return }
        if store.add(apps) > 0 { NSSound.beep() }   // the folder is full
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

    /// So the Dock doesn't go on showing an old icon, or the wrong light or dark, once we've quit.
    func applicationWillTerminate(_ notification: Notification) {
        guard Self.persistIconToBundle, Bundle.main.bundleURL.pathExtension == "app" else { return }
        BundleIcon.write(for: store, dark: NSApp.effectiveAppearance.isDark, to: Bundle.main.bundleURL)
    }

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
        if store.add(urls) > 0 { NSSound.beep() }   // the folder is full
        panel.show(near: anchor)
    }

    // MARK: - Dock icon

    /// Redraws the live Dock icon when the first nine apps, the colour, or light and dark change.
    /// @Published sends new values just before the store has them; `items` and `tint` are those.
    private func refreshDockIcon(items: [FolderItem]? = nil, tint: FolderTint? = nil, waitForPanel: Bool = true) {
        let items = items ?? store.items
        let tint = tint ?? store.tint
        let dark = NSApp.effectiveAppearance.isDark
        let shown = ShownIcon(items: items.prefix(9).map(\.id), tint: tint, dark: dark)
        guard shown != shownIcon else { return }
        // A change made in the open folder, such as an app put down, shows once it has settled.
        if waitForPanel, panel.isOpen {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(redrawDockIcon), object: nil)
            perform(#selector(redrawDockIcon), with: nil, afterDelay: 0.4)
            return
        }
        shownIcon = shown
        NSApp.applicationIconImage = FolderIcon.bitmap(from: items.prefix(9).map(store.icon(for:)), tint: tint, dark: dark)
        scheduleBundleIcon()
    }

    @objc private func redrawDockIcon() {
        refreshDockIcon(waitForPanel: false)
    }

    /// The icon in our bundle is written once the changes stop (dragging through the colour wheel
    /// sends many) and the folder is closed, as writing it holds things up for a moment.
    private func scheduleBundleIcon() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(writeBundleIcon), object: nil)
        perform(#selector(writeBundleIcon), with: nil, afterDelay: 0.5)
    }

    /// Light or dark alone waits until we quit: while we run, the Dock shows the live icon.
    @objc private func writeBundleIcon() {
        guard Self.persistIconToBundle, Bundle.main.bundleURL.pathExtension == "app", !panel.isOpen else { return }
        BundleIcon.write(for: store, dark: NSApp.effectiveAppearance.isDark, to: Bundle.main.bundleURL,
                         evenForAppearance: false)
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
