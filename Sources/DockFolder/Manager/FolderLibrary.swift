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
        // so draw it into its bundle for it.
        iconSubscription = Publishers.CombineLatest(store.$items, store.$tint)
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self, !self.checkRunning() else { return }
                self.writeIcon()
            }
    }

    /// Draws the folder's icon into its bundle, which is what the Dock shows while it isn't running.
    func writeIcon() {
        let image = FolderIcon.make(from: store.previewIcons(), tint: store.tint,
                                    dark: NSApp.effectiveAppearance.isDark)
        _ = NSWorkspace.shared.setIcon(image, forFile: url.path, options: [])
    }

    fileprivate func checkRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
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
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatus() }
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
            at: factory.foldersDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var found: [ManagedFolder] = []
        for url in urls where url.pathExtension == "app" {
            guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                  info["CFBundleExecutable"] as? String == "DockFolder",
                  info[AppRole.infoKey] as? String != "manager",
                  let bundleID = info["CFBundleIdentifier"] as? String else { continue }
            let name = info["CFBundleDisplayName"] as? String
                ?? info["CFBundleName"] as? String
                ?? url.deletingPathExtension().lastPathComponent
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

    /// Whether each folder is running, kept in the Dock, and made by this build.
    func refreshStatus() {
        let dock = DockPreferences.appPaths()
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
    func createFolder(named name: String, tint: FolderTint, apps: [URL], keepInDock: Bool) async throws -> ManagedFolder {
        let plan = try factory.plan(name: name, existingBundleIDs: Set(folders.map(\.bundleID)))
        let factory = factory
        try await Task.detached(priority: .userInitiated) { try factory.build(plan) }.value

        // Save the apps before anything watches the folder, so its icon isn't drawn twice.
        FolderStore(name: plan.name, bundleID: plan.bundleID, directory: dataDirectory).reset(apps: apps, tint: tint)
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

    /// Starts the folder in the background, so its Dock icon shows its apps and reacts to clicks.
    func launch(_ folder: ManagedFolder) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let path = folder.url.path
        NSWorkspace.shared.openApplication(at: folder.url, configuration: configuration) { _, error in
            if let error {
                NSLog("DockFolder: couldn't start %@: %@", path, error.localizedDescription)
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
        if FileManager.default.fileExists(atPath: folder.store.dataURL.path) {
            try? FileManager.default.trashItem(at: folder.store.dataURL, resultingItemURL: nil)
        }
        folders.removeAll { $0.id == folder.id }
    }

    /// Asks the folder to quit and waits up to two seconds for it. Returns whether it was running.
    @discardableResult
    private func quit(_ folder: ManagedFolder) async -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: folder.bundleID)
        guard !running.isEmpty else { return false }
        running.forEach { $0.terminate() }
        for _ in 0..<40 where running.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }
}
