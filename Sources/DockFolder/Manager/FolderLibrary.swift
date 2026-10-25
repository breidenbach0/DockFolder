import AppKit
import Combine

/// One folder app, as the DockFolder window sees it.
@MainActor
final class ManagedFolder: ObservableObject, Identifiable {
    let url: URL
    let name: String
    let bundleID: String
    /// The folder's apps and colour. Edits here reach the running folder through the store.
    let store: FolderStore
    @Published fileprivate(set) var isInDock = false
    @Published fileprivate(set) var isRunning = false
    /// Made by a different DockFolder build; updating gives it this build's code and look.
    @Published fileprivate(set) var isOutdated = false

    private var iconSubscription: AnyCancellable?

    nonisolated var id: String { bundleID }

    init(url: URL, name: String, bundleID: String, dataDirectory: URL?) {
        self.url = url
        self.name = name
        self.bundleID = bundleID
        store = FolderStore(name: name, bundleID: bundleID, directory: dataDirectory)

        // A running folder redraws its own Dock icon. One that isn't running can't,
        // so draw it into its bundle for it. (By the end of the debounce the store has the values.)
        iconSubscription = Publishers.CombineLatest(store.$items, store.$tint)
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self, !self.checkRunning() else { return }
                self.writeIcon()
            }
    }

    /// The folder's icon at `size`, drawn again only when its first nine apps or colour change,
    /// so the window doesn't redraw it every time something else changes.
    func icon(size: CGFloat, dark: Bool) -> NSImage {
        let key = "\(size)|\(dark)|" + store.items.prefix(9).map(\.id.uuidString).joined(separator: ",")
            + "|" + store.tint.savedName
        if let cached = icons[key] { return cached }
        if icons.count > 8 { icons.removeAll() }
        let image = FolderIcon.make(from: store.previewIcons(), tint: store.tint, dark: dark, size: size)
        icons[key] = image
        return image
    }

    private var icons: [String: NSImage] = [:]

    /// Draws the folder's icon into its bundle, which is what the Dock shows while it isn't
    /// running, unless the icon there already shows the same.
    func writeIcon() {
        BundleIcon.write(for: store, dark: NSApp.effectiveAppearance.isDark, to: url)
    }

    fileprivate func checkRunning() -> Bool {
        !runningCopies().isEmpty
    }

    /// This folder's running process, matched by path as well as bundle ID.
    fileprivate func runningCopies() -> [NSRunningApplication] {
        let path = url.standardizedFileURL.path
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.bundleURL?.standardizedFileURL.path == path }
    }
}

/// The folders in ~/Applications/Dock Folders, and the things the DockFolder window does to them.
@MainActor
final class FolderLibrary: ObservableObject {
    struct NewFolderRequest: Identifiable {
        let id = UUID()
        var apps: [URL]
    }

    @Published private(set) var folders: [ManagedFolder] = []
    /// Set to show the New Folder sheet, with any apps it should start with.
    @Published var newFolderRequest: NewFolderRequest?
    /// The apps kept in the Dock, in Dock order, except folders. Shown under a folder in the
    /// window, to be dragged into it.
    @Published private(set) var dockApps: [URL] = []
    private var dockRestart: Task<Void, Never>?
    private let dockIcons = NSCache<NSString, NSImage>()
    private let dockNames = NSCache<NSString, NSString>()

    let factory: FolderFactory
    private let dataDirectory: URL?
    private let buildStamp: String?
    private var observers: [ObserverToken] = []

    init(template: URL = Bundle.main.bundleURL,
         foldersDirectory: URL = FolderFactory.defaultFoldersDirectory,
         dataDirectory: URL? = nil) {
        factory = FolderFactory(template: template, foldersDirectory: foldersDirectory)
        self.dataDirectory = dataDirectory
        buildStamp = FolderFactory.buildStamp(ofApp: template)
        reload()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            // Only folders starting or quitting change anything shown.
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier?.hasPrefix(FolderFactory.bundleIDPrefix) == true else { return }
                MainActor.assumeIsolated { self?.refreshRunning() }
            }
            observers.append(ObserverToken(center: center, token: token))
        }
    }

    func folder(withID id: ManagedFolder.ID?) -> ManagedFolder? {
        folders.first { $0.id == id }
    }

    func requestNewFolder(with apps: [URL] = []) {
        newFolderRequest = NewFolderRequest(apps: apps)
    }

    /// Why `name` can't be used for a new folder, or nil if it can.
    func problem(withName name: String) -> String? {
        do {
            _ = try factory.plan(name: name, existingBundleIDs: [])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Reading

    /// Finds the folder apps in Dock Folders, keeping the ones already loaded.
    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: factory.foldersDirectory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        var candidates: [(url: URL, name: String, bundleID: String)] = []
        for url in urls where url.pathExtension == "app" {
            guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                  info["CFBundleExecutable"] as? String == "DockFolder",
                  info[AppRole.infoKey] as? String != "manager",
                  let bundleID = info["CFBundleIdentifier"] as? String,
                  // Its saved apps' file is named after it, so only IDs DockFolder makes.
                  FolderFactory.isFolderBundleID(bundleID) else { continue }
            let name = info["CFBundleDisplayName"] as? String
                ?? info["CFBundleName"] as? String
                ?? url.deletingPathExtension().lastPathComponent
            candidates.append((url, name, bundleID))
        }

        // Two folder apps should never share a bundle ID, and with it their saved apps. If a stray
        // copy turns up anyway, show one: the copy kept in the Dock, otherwise the newest.
        let dock = DockPreferences.appPaths()
        let chosen = Dictionary(grouping: candidates, by: \.bundleID).values.compactMap { copies in
            copies.max { Self.preference(of: $0.url, dock: dock) < Self.preference(of: $1.url, dock: dock) }
        }

        var found: [ManagedFolder] = []
        for (url, name, bundleID) in chosen {
            let path = url.standardizedFileURL.path
            if let existing = folders.first(where: {
                $0.bundleID == bundleID && $0.name == name && $0.url.standardizedFileURL.path == path
            }) {
                found.append(existing)
            } else {
                found.append(ManagedFolder(url: url, name: name, bundleID: bundleID, dataDirectory: dataDirectory))
            }
        }
        found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if found.count != folders.count || zip(found, folders).contains(where: { $0 !== $1 }) {
            folders = found
        }
        refreshStatus()
    }

    /// An app from the Dock that can go in a folder: one that's there, and not a folder itself.
    private static func canMoveIntoFolder(_ url: URL) -> Bool {
        guard url.pathExtension == "app", FileManager.default.fileExists(atPath: url.path) else { return false }
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleExecutable"] as? String != "DockFolder"
    }

    private static func preference(of url: URL, dock: Set<String>) -> (Int, Date) {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return (dock.contains(url.standardizedFileURL.path) ? 1 : 0, modified)
    }

    /// Whether each folder is running.
    func refreshRunning() {
        for folder in folders {
            let running = folder.checkRunning()
            if folder.isRunning != running { folder.isRunning = running }
        }
    }

    /// An app in the Dock strip's icon, looked up once.
    func icon(forDockApp app: URL) -> NSImage {
        if let cached = dockIcons.object(forKey: app.path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        dockIcons.setObject(icon, forKey: app.path as NSString)
        return icon
    }

    /// An app in the Dock strip's name, looked up once.
    func name(forDockApp app: URL) -> String {
        if let cached = dockNames.object(forKey: app.path as NSString) { return cached as String }
        let name = FileManager.default.displayName(atPath: app.path)
        dockNames.setObject(name as NSString, forKey: app.path as NSString)
        return name
    }

    /// Whether each folder is running, kept in the Dock, and made by this build; and what's in the Dock.
    func refreshStatus() {
        let dockURLs = DockPreferences.appURLs()
        let movable = dockURLs.filter(Self.canMoveIntoFolder)
        if movable != dockApps { dockApps = movable }
        let dock = Set(dockURLs.map { $0.standardizedFileURL.path })
        for folder in folders {
            let running = folder.checkRunning()
            let inDock = dock.contains(folder.url.standardizedFileURL.path)
            let outdated = buildStamp != nil && FolderFactory.buildStamp(ofApp: folder.url) != buildStamp
            if folder.isRunning != running { folder.isRunning = running }
            if folder.isInDock != inDock { folder.isInDock = inDock }
            if folder.isOutdated != outdated { folder.isOutdated = outdated }
        }
    }

    // MARK: - Changing

    /// Makes a folder with these apps in it, optionally keeps it in the Dock, and starts it
    /// so its Dock icon shows the apps.
    func createFolder(named name: String, tint: FolderTint, style: FolderStyle = .pages, apps: [URL],
                      keepInDock: Bool) async throws -> ManagedFolder {
        let plan = try factory.plan(name: name, existingBundleIDs: Set(folders.map(\.bundleID)))
        let factory = factory
        try await Task.detached(priority: .userInitiated) { try factory.build(plan) }.value

        // Save the apps before anything watches the folder, so its icon isn't drawn twice.
        FolderStore(name: plan.name, bundleID: plan.bundleID, directory: dataDirectory)
            .reset(apps: apps, tint: tint, style: style)
        let folder = ManagedFolder(url: plan.url, name: plan.name, bundleID: plan.bundleID, dataDirectory: dataDirectory)
        folder.writeIcon()   // so the Dock has the right icon before the folder first runs
        if keepInDock {
            DockPreferences.add(plan.url)
            DockPreferences.restartDock()
        }
        folders.append(folder)
        reload()
        launch(folder)
        return folder
    }

    /// Moves an app from the Dock into a folder. The Dock restarts to let go of its icon once,
    /// a moment after the last move, so several apps can be moved in a row. Returns false, and
    /// leaves the Dock alone, if the folder is full.
    @discardableResult
    func moveFromDock(_ app: URL, into folder: ManagedFolder) -> Bool {
        // Only an app that's in the Dock: the drag could carry any path.
        let path = app.standardizedFileURL.path
        guard dockApps.contains(where: { $0.standardizedFileURL.path == path }),
              folder.store.add([app]) == 0 else { return false }
        DockPreferences.remove(app)
        refreshStatus()
        dockRestart?.cancel()
        dockRestart = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            DockPreferences.restartDock()
        }
        return true
    }

    /// Starts the folder in the background, so its Dock icon shows its apps and reacts to clicks.
    func launch(_ folder: ManagedFolder) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let path = folder.url.path
        NSWorkspace.shared.openApplication(at: folder.url, configuration: configuration) { _, error in
            if let error {
                FolderStore.log.error("couldn't start \(path): \(error.localizedDescription)")
            }
        }
    }

    func setKeepInDock(_ keep: Bool, for folder: ManagedFolder) {
        if keep {
            DockPreferences.add(folder.url)
        } else {
            DockPreferences.remove(folder.url)
        }
        DockPreferences.restartDock()
        folder.isInDock = keep
    }

    /// Rebuilds the folder from this version of DockFolder. Its apps, colour and Dock place stay.
    func update(_ folder: ManagedFolder) async throws {
        let wasRunning = await quit(folder)
        let factory = factory
        let (url, name, bundleID) = (folder.url, folder.name, folder.bundleID)
        try await Task.detached(priority: .userInitiated) {
            try factory.rebuild(at: url, name: name, bundleID: bundleID)
        }.value
        folder.writeIcon()
        if wasRunning { launch(folder) }
        refreshStatus()
    }

    /// Updates every folder made by another build, as after DockFolder updated itself.
    /// Returns the names of any that couldn't be updated.
    func updateOutdatedFolders() async -> [String] {
        refreshStatus()
        var failed: [String] = []
        for folder in folders where folder.isOutdated {
            do {
                try await update(folder)
            } catch {
                Updater.log.error("couldn't update \(folder.name): \(error.localizedDescription)")
                failed.append(folder.name)
            }
        }
        return failed
    }

    /// Why `folder` can't be renamed to `name`, or nil if it can.
    func problem(renaming folder: ManagedFolder, to name: String) -> String? {
        do {
            _ = try factory.renameDestination(for: folder.url, to: name)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Renames the folder's app, its Dock tile and the title on its panel. It keeps its apps,
    /// colour and place in the Dock. A running folder is quit first and started again after.
    func rename(_ folder: ManagedFolder, to newName: String) async throws {
        let name = try FolderFactory.validatedName(newName)
        guard name != folder.name else { return }
        let wasRunning = await quit(folder)
        let wasInDock = DockPreferences.contains(folder.url)
        let factory = factory
        let (url, bundleID) = (folder.url, folder.bundleID)
        let renamed: URL
        do {
            renamed = try await Task.detached(priority: .userInitiated) {
                try factory.rename(at: url, bundleID: bundleID, to: name)
            }.value
        } catch {
            if wasRunning { launch(folder) }
            throw error
        }

        if wasInDock {
            DockPreferences.replace(url, with: renamed)
            DockPreferences.restartDock()
        }
        reload()
        guard let updated = self.folder(withID: bundleID) else { return }
        updated.writeIcon()   // signing the renamed copy dropped the icon written into it
        if wasRunning { launch(updated) }
    }

    /// Quits the folder, takes it out of the Dock, and moves it and its saved apps to the Trash.
    func delete(_ folder: ManagedFolder) async throws {
        await quit(folder)
        if DockPreferences.contains(folder.url) {
            DockPreferences.remove(folder.url)
            DockPreferences.restartDock()
        }
        try FileManager.default.trashItem(at: folder.url, resultingItemURL: nil)
        // The saved apps belong to the bundle ID; another copy still using it keeps them.
        if FileManager.default.fileExists(atPath: folder.store.dataURL.path),
           Self.folderApps(withBundleID: folder.bundleID, in: factory.foldersDirectory).isEmpty {
            try? FileManager.default.trashItem(at: folder.store.dataURL, resultingItemURL: nil)
        }
        folders.removeAll { $0.id == folder.id }
        reload()   // a copy that was hidden behind the deleted one shows up again
    }

    /// Folder apps on disk with this bundle ID.
    static func folderApps(withBundleID bundleID: String, in directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { url in
            url.pathExtension == "app"
                && NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String == bundleID
        }
    }

    /// Asks the folder to quit and waits up to two seconds for it. Returns whether it was running.
    @discardableResult
    private func quit(_ folder: ManagedFolder) async -> Bool {
        let running = folder.runningCopies()
        guard !running.isEmpty else { return false }
        running.forEach { $0.terminate() }
        for _ in 0..<40 where running.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }
}
