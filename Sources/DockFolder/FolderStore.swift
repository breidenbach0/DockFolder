import AppKit
import Combine

struct FolderItem: Codable, Identifiable, Equatable {
    var id: UUID
    /// Where the app was when it was added.
    var path: String
    /// Used to find the app again if it moves or is reinstalled somewhere else.
    var bundleID: String?
}

/// The apps in this folder, saved as JSON in Application Support.
/// Each folder app has its own bundle ID, so each gets its own file.
///
/// The folder itself and the DockFolder window can both edit the file. After saving, each
/// posts a distributed notification so the other re-reads it, and each re-reads the file
/// before changing it, so neither overwrites the other's edits.
@MainActor
final class FolderStore: ObservableObject {
    /// Posted through DistributedNotificationCenter after a folder's file is saved.
    /// The object is the folder's bundle ID.
    static let didChangeNotification = Notification.Name("dev.local.dockfolder.folderDidChange")

    @Published private(set) var items: [FolderItem] = []
    @Published private(set) var tint: FolderTint = .clear
    @Published private(set) var style: FolderStyle = .pages
    let name: String
    let bundleID: String
    let dataURL: URL

    private let iconCache = NSCache<NSString, NSImage>()
    /// The file's modification date when we last read or wrote it.
    private var knownFileDate: Date?
    private var changeObserver: ObserverToken?

    convenience init(bundle: Bundle = .main, directory: URL? = nil) {
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? "Folder"
        self.init(name: name, bundleID: bundle.bundleIdentifier ?? "dev.local.dockfolder", directory: directory)
    }

    init(name: String, bundleID: String, directory: URL? = nil) {
        self.name = name
        self.bundleID = bundleID
        let base = directory ?? Self.defaultDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dataURL = base.appendingPathComponent("\(bundleID).json")

        load()

        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(forName: Self.didChangeNotification, object: bundleID, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChangedOnDisk() }
        }
        changeObserver = ObserverToken(center: center, token: token)
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DockFolder", isDirectory: true)
    }

    /// The most apps this folder holds, for its layout.
    var capacity: Int { style.capacity }

    var isFull: Bool { items.count >= capacity }

    // MARK: - Editing

    /// Adds as many of the apps as the folder has room for. Returns how many didn't fit.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        reloadIfChangedOnDisk()
        let all = Self.appending(urls, to: items)
        // A folder from before there were limits may already hold more; it keeps them.
        let updated = Array(all.prefix(max(capacity, items.count)))
        if updated != items {
            items = updated
            save()
        }
        return all.count - updated.count
    }

    func remove(_ item: FolderItem) {
        reloadIfChangedOnDisk()
        items.removeAll { $0.id == item.id }
        save()
    }

    /// Moves an item one place left (-1) or right (+1).
    func move(_ item: FolderItem, by offset: Int) {
        reloadIfChangedOnDisk()
        guard let from = items.firstIndex(where: { $0.id == item.id }),
              items.indices.contains(from + offset) else { return }
        items.swapAt(from, from + offset)
        save()
    }

    func setTint(_ newTint: FolderTint) {
        reloadIfChangedOnDisk()
        guard newTint != tint else { return }
        tint = newTint
        save()
    }

    /// Switches between pages and the grid. Refused if the folder holds more apps than fit.
    @discardableResult
    func setStyle(_ newStyle: FolderStyle) -> Bool {
        reloadIfChangedOnDisk()
        guard items.count <= newStyle.capacity else { return false }
        guard newStyle != style else { return true }
        style = newStyle
        save()
        return true
    }

    /// Starts the folder over with these apps. For a folder that's just been made.
    func reset(apps: [URL], tint newTint: FolderTint, style newStyle: FolderStyle = .pages) {
        items = Array(Self.appending(apps, to: []).prefix(newStyle.capacity))
        tint = newTint
        style = newStyle
        save()
    }

    /// Picks up changes another process saved since we last read or wrote the file.
    func reloadIfChangedOnDisk() {
        guard fileDate() != knownFileDate else { return }
        load()
    }

    private static func appending(_ urls: [URL], to existing: [FolderItem]) -> [FolderItem] {
        let ownBundle = Bundle.main.bundleURL.standardizedFileURL
        var updated = existing
        for url in urls where url.isFileURL && url.standardizedFileURL != ownBundle {
            let path = url.standardizedFileURL.path
            let bundleID = url.pathExtension == "app" ? Bundle(url: url)?.bundleIdentifier : nil
            let duplicate = updated.contains { item in
                item.path == path || (bundleID != nil && item.bundleID == bundleID)
            }
            if !duplicate {
                updated.append(FolderItem(id: UUID(), path: path, bundleID: bundleID))
            }
        }
        return updated
    }

    // MARK: - Looking things up

    /// The item's current location, following the app by bundle ID if it has moved.
    /// Returns nil if it can't be found at all.
    func url(for item: FolderItem) -> URL? {
        if FileManager.default.fileExists(atPath: item.path) {
            return URL(fileURLWithPath: item.path)
        }
        guard let bundleID = item.bundleID else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func displayName(for item: FolderItem) -> String {
        FileManager.default.displayName(atPath: url(for: item)?.path ?? item.path)
    }

    func icon(for item: FolderItem) -> NSImage {
        guard let url = url(for: item) else {
            // Not cached, so the real icon comes back once the app reappears.
            return NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        let key = url.path as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache.setObject(icon, forKey: key)
        return icon
    }

    /// The icons the folder's Dock icon shows: the first nine apps.
    func previewIcons() -> [NSImage] {
        items.prefix(9).map(icon(for:))
    }

    // MARK: - Opening

    /// Returns false if the item can't be found.
    @discardableResult
    func open(_ item: FolderItem) -> Bool {
        guard let url = url(for: item) else { return false }
        if url.pathExtension == "app" {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    NSLog("DockFolder: couldn't open %@: %@", url.path, error.localizedDescription)
                }
            }
        } else {
            NSWorkspace.shared.open(url)
        }
        return true
    }

    func revealInFinder(_ item: FolderItem) {
        guard let url = url(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Persistence

    private struct FolderFile: Codable {
        var version: Int
        var items: [FolderItem]
        /// Missing in files saved before folders had a colour.
        var tint: String?
        /// Missing in files saved before folders had a choice of layout.
        var style: String?
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: dataURL.path) else {
            apply(items: [], tint: .clear, style: .pages)
            knownFileDate = nil
            return
        }
        // Read the date first: if another save lands in between, we just read the file again later.
        let date = fileDate()
        do {
            let data = try Data(contentsOf: dataURL)
            let file = try JSONDecoder().decode(FolderFile.self, from: data)
            apply(items: file.items, tint: FolderTint(savedName: file.tint),
                  style: FolderStyle(savedName: file.style, itemCount: file.items.count))
            knownFileDate = date
        } catch {
            // Keep the unreadable file for inspection instead of overwriting it on the next save.
            let backup = dataURL.deletingLastPathComponent()
                .appendingPathComponent(dataURL.lastPathComponent + ".unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: dataURL, to: backup)
            knownFileDate = nil
            NSLog("DockFolder: couldn't read %@ (%@); moved it to %@",
                  dataURL.path, error.localizedDescription, backup.lastPathComponent)
        }
    }

    /// Only publishes what actually changed, so a reload doesn't redraw the Dock icon for nothing.
    private func apply(items newItems: [FolderItem], tint newTint: FolderTint, style newStyle: FolderStyle) {
        if items != newItems { items = newItems }
        if tint != newTint { tint = newTint }
        if style != newStyle { style = newStyle }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let file = FolderFile(version: 1, items: items, tint: tint == .clear ? nil : tint.savedName,
                                  style: style.rawValue)
            try encoder.encode(file).write(to: dataURL, options: .atomic)
            knownFileDate = fileDate()
        } catch {
            NSLog("DockFolder: couldn't save %@: %@", dataURL.path, error.localizedDescription)
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            Self.didChangeNotification, object: bundleID, userInfo: nil, deliverImmediately: true)
    }

    private func fileDate() -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: dataURL.path)
        return attributes?[.modificationDate] as? Date
    }
}

/// Removes a block-based notification observer when it's released.
final class ObserverToken {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit { center.removeObserver(token) }
}
