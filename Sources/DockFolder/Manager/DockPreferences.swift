import Foundation

/// The apps kept in the Dock, read from and written to the Dock's own preferences, the same
/// way `defaults write com.apple.dock persistent-apps` does. The Dock only reads them when it
/// starts, so a change needs `restartDock()`.
enum DockPreferences {
    private static let domain = "com.apple.dock" as CFString
    private static let key = "persistent-apps" as CFString

    /// Paths of the apps kept in the Dock.
    static func appPaths() -> Set<String> {
        Set(persistentApps().compactMap(path(ofTile:)))
    }

    /// The apps kept in the Dock, in Dock order.
    static func appURLs() -> [URL] {
        appURLs(inTiles: persistentApps())
    }

    static func appURLs(inTiles tiles: [[String: Any]]) -> [URL] {
        tiles.compactMap(path(ofTile:)).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func contains(_ app: URL) -> Bool {
        appPaths().contains(app.standardizedFileURL.path)
    }

    static func add(_ app: URL) {
        guard !contains(app) else { return }
        var apps = persistentApps()
        apps.append([
            "tile-data": ["file-data": ["_CFURLString": app.absoluteString, "_CFURLStringType": 15]],
            "tile-type": "file-tile",
        ])
        save(apps)
    }

    static func remove(_ app: URL) {
        let path = app.standardizedFileURL.path
        save(persistentApps().filter { self.path(ofTile: $0) != path })
    }

    /// Points the Dock tile for `old` at `new`, keeping its place in the Dock.
    static func replace(_ old: URL, with new: URL) {
        save(replacingTile(for: old, with: new, in: persistentApps()))
    }

    /// The tiles, with the one for `old` pointing at `new`. Its saved bookmark and label are
    /// dropped, so the Dock reads both afresh from the renamed app.
    static func replacingTile(for old: URL, with new: URL, in apps: [[String: Any]]) -> [[String: Any]] {
        let oldPath = old.standardizedFileURL.path
        return apps.map { tile in
            guard path(ofTile: tile) == oldPath, var tileData = tile["tile-data"] as? [String: Any] else { return tile }
            tileData["file-data"] = ["_CFURLString": new.absoluteString, "_CFURLStringType": 15]
            tileData["file-label"] = new.deletingPathExtension().lastPathComponent
            tileData["book"] = nil
            var updated = tile
            updated["tile-data"] = tileData
            return updated
        }
    }

    static func restartDock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }

    /// The app a Dock tile points to. The Dock saves it as a file URL (type 15);
    /// `defaults write`, as make-folder.sh uses it, saves a plain path (type 0).
    static func path(ofTile tile: [String: Any]) -> String? {
        guard let tileData = tile["tile-data"] as? [String: Any],
              let fileData = tileData["file-data"] as? [String: Any],
              let string = fileData["_CFURLString"] as? String else { return nil }
        let url = (fileData["_CFURLStringType"] as? Int) == 0 ? URL(fileURLWithPath: string) : URL(string: string)
        return url?.standardizedFileURL.path
    }

    private static func persistentApps() -> [[String: Any]] {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] ?? []
    }

    private static func save(_ apps: [[String: Any]]) {
        CFPreferencesSetAppValue(key, apps as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
    }
}
