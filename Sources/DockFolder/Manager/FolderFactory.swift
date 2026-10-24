import Foundation

/// Makes folder apps: copies of the DockFolder app with their own name and bundle ID, so each
/// gets its own Dock icon and its own saved list of apps. The same steps as
/// scripts/make-folder.sh, except that it touches neither the Dock nor the folder's apps.
struct FolderFactory {
    /// The DockFolder app that folders are copied from.
    var template: URL
    /// Where folders are kept.
    var foldersDirectory: URL

    static let bundleIDPrefix = "dev.local.dockfolder."
    /// Info.plist key set by build-app.sh. Copies keep it, which shows which build made them.
    static let buildKey = "DockFolderBuild"

    static var defaultFoldersDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Dock Folders", isDirectory: true)
    }

    enum Failure: LocalizedError, Equatable {
        case emptyName
        case invalidName
        case nameTaken(String)
        case notAnApp
        case signingFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyName:
                return "Give the folder a name."
            case .invalidName:
                return "A folder name can’t contain “/” or “:”, or start with a dot."
            case .nameTaken(let name):
                return "There’s already a folder called “\(name)”."
            case .notAnApp:
                return "Folders can only be made from the DockFolder app. Build it with scripts/build-app.sh and open build/DockFolder.app."
            case .signingFailed(let message):
                return "Couldn’t sign the new folder: \(message)"
            }
        }
    }

    /// A folder that's about to be made.
    struct Plan: Equatable {
        var name: String
        var bundleID: String
        var url: URL
    }

    /// Checks the name and picks a bundle ID that no other folder uses.
    func plan(name rawName: String, existingBundleIDs: Set<String>) throws -> Plan {
        let name = try Self.validatedName(rawName)
        let url = foldersDirectory.appendingPathComponent("\(name).app", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.nameTaken(name) }
        return Plan(name: name, bundleID: Self.bundleID(for: name, avoiding: existingBundleIDs), url: url)
    }

    /// Copies the template to `plan.url` with the folder's name and bundle ID, and signs it.
    /// It's put together in a staging folder first, so a half-made app never appears.
    func build(_ plan: Plan) throws {
        try build(name: plan.name, bundleID: plan.bundleID, at: plan.url, replacingExisting: false)
    }

    /// Rebuilds an existing folder app from the template. Its apps are saved under its bundle
    /// ID and its Dock tile points at its path, so keeping both keeps everything.
    func rebuild(at url: URL, name: String, bundleID: String) throws {
        try build(name: name, bundleID: bundleID, at: url, replacingExisting: true)
    }

    /// Where the folder at `url` goes when it's renamed to `name`. Throws if the name can't be used.
    func renameDestination(for url: URL, to rawName: String) throws -> URL {
        let name = try Self.validatedName(rawName)
        let destination = url.deletingLastPathComponent().appendingPathComponent("\(name).app", isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path), !Self.isSameItem(destination, url) {
            throw Failure.nameTaken(name)
        }
        return destination
    }

    /// Renames a folder app: a signed copy with the new name takes its place, then moves to
    /// `<name>.app`. The bundle ID stays, so the folder keeps its apps and colour. Returns the new URL.
    func rename(at url: URL, bundleID: String, to rawName: String) throws -> URL {
        let name = try Self.validatedName(rawName)
        let destination = try renameDestination(for: url, to: name)
        let fileManager = FileManager.default
        let staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: url, create: true)
        defer { try? fileManager.removeItem(at: staging) }

        let staged = staging.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try fileManager.copyItem(at: url, to: staged)
        Self.removeCustomIcon(from: staged)
        Self.removeQuarantine(from: staged)
        try Self.rewriteInfoPlist(in: staged, name: name, bundleID: bundleID)
        try Self.sign(staged)
        _ = try fileManager.replaceItemAt(url, withItemAt: staged, options: .usingNewMetadataOnly)

        guard url.lastPathComponent != destination.lastPathComponent else { return destination }
        if Self.isSameItem(url, destination) {
            // Only the case changes, on a case-insensitive disk: move it aside first.
            let aside = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).app")
            try fileManager.moveItem(at: url, to: aside)
            try fileManager.moveItem(at: aside, to: destination)
        } else {
            try fileManager.moveItem(at: url, to: destination)
        }
        return destination
    }

    // MARK: - Names

    static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.emptyName }
        guard !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else { throw Failure.invalidName }
        return name
    }

    /// "My Apps" → "dev.local.dockfolder.my-apps", as make-folder.sh does; "-2", "-3"… if taken.
    static func bundleID(for name: String, avoiding taken: Set<String>) -> String {
        let slug = slug(for: name)
        let base = bundleIDPrefix + (slug.isEmpty ? "folder" : slug)
        var candidate = base
        var number = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(number)"
            number += 1
        }
        return candidate
    }

    /// Lowercase ASCII letters and digits, with a dash for each run of anything else.
    static func slug(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var slug = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    private static func isSameItem(_ first: URL, _ second: URL) -> Bool {
        let ids = [first, second].map { try? $0.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier }
        guard let a = ids[0], let b = ids[1] else { return false }
        return a.isEqual(b)
    }

    /// The build stamp of a DockFolder app or folder, if it has one.
    static func buildStamp(ofApp url: URL) -> String? {
        NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?[buildKey] as? String
    }

    // MARK: - Building

    private func build(name: String, bundleID: String, at destination: URL, replacingExisting: Bool) throws {
        guard template.pathExtension == "app" else { throw Failure.notAnApp }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: foldersDirectory, withIntermediateDirectories: true)
        let staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: foldersDirectory, create: true)
        defer { try? fileManager.removeItem(at: staging) }

        let staged = staging.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try fileManager.copyItem(at: template, to: staged)
        Self.removeCustomIcon(from: staged)
        Self.removeQuarantine(from: staged)
        try Self.rewriteInfoPlist(in: staged, name: name, bundleID: bundleID)
        try Self.sign(staged)

        if replacingExisting {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
        } else {
            guard !fileManager.fileExists(atPath: destination.path) else { throw Failure.nameTaken(name) }
            try fileManager.moveItem(at: staged, to: destination)
        }
    }

    /// A folder that has run writes its own icon into its bundle (an `Icon\r` file and a Finder
    /// flag). codesign won't sign a bundle with that file in it, and folders draw their own icon.
    private static func removeCustomIcon(from bundle: URL) {
        try? FileManager.default.removeItem(at: bundle.appendingPathComponent("Icon\r"))
        removexattr(bundle.path, "com.apple.FinderInfo", 0)
    }

    /// A DockFolder downloaded from the web carries a quarantine flag. Copying would pass it on,
    /// and every new folder would need approving in Privacy & Security. Folders run the same code
    /// the user approved when they first opened DockFolder.
    static func removeQuarantine(from bundle: URL) {
        removexattr(bundle.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard let items = FileManager.default.enumerator(atPath: bundle.path) else { return }
        for case let item as String in items {
            removexattr(bundle.appendingPathComponent(item).path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    static func rewriteInfoPlist(in bundle: URL, name: String, bundleID: String) throws {
        let url = bundle.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: url)
        guard var info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        info["CFBundleIdentifier"] = bundleID
        info["CFBundleName"] = name
        info["CFBundleDisplayName"] = name
        info[AppRole.infoKey] = nil   // a copy is a folder, not the DockFolder app
        let updated = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try updated.write(to: url, options: .atomic)
    }

    /// Ad-hoc signature, like build-app.sh: enough to run locally on Apple silicon.
    private static func sign(_ bundle: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", bundle.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.signingFailed(text.isEmpty ? "codesign exited with status \(process.terminationStatus)" : text)
        }
    }
}
