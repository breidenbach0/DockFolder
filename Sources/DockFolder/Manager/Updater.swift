import AppKit
import CryptoKit
import OSLog

/// A version like 0.4.0, compared number by number, so 0.10 comes after 0.9.
struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    let numbers: [Int]

    /// Reads "0.4.0", or a tag like "v0.4.0". Nil for anything else.
    init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in part.allSatisfy(\.isASCII) ? Int(part) : nil }
        guard !parts.isEmpty, numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        self.numbers = numbers
    }

    /// The running app's version, from its Info.plist.
    static var current: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for index in 0..<max(a.numbers.count, b.numbers.count) {
            let x = index < a.numbers.count ? a.numbers[index] : 0
            let y = index < b.numbers.count ? b.numbers[index] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// 0.4 and 0.4.0 are the same version.
    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    var description: String { numbers.map(String.init).joined(separator: ".") }
}

/// A DockFolder release on GitHub.
struct Release: Equatable, Sendable {
    /// What the updater installs: the app, zipped. Releases also carry DockFolder.dmg for people.
    static let archiveName = "DockFolder.zip"

    var version: AppVersion
    var title: String
    /// The release's page, with its notes and the disk image.
    var page: URL
    /// The zipped app. Nil for a release without one: it can only be downloaded from its page.
    var archive: URL?
    /// The archive's SHA-256 as GitHub reports it, to check the download against.
    var sha256: String?

    /// The release in GitHub's answer about the latest release. Nil for a draft, a prerelease,
    /// or a tag that isn't a version number.
    init?(gitHubJSON data: Data) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(Payload.self, from: data),
              payload.draft != true, payload.prerelease != true,
              let version = AppVersion(payload.tagName) else { return nil }
        let asset = payload.assets.first { $0.name == Self.archiveName }
        self.version = version
        title = payload.name ?? "DockFolder \(version)"
        page = payload.htmlUrl
        archive = asset?.browserDownloadUrl
        sha256 = asset?.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
    }

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
            let digest: String?
        }

        let tagName: String
        let name: String?
        let htmlUrl: URL
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }
}

/// Where releases are looked up, and the only place updates are downloaded from.
struct UpdateSource {
    /// GitHub's API address for the latest release.
    var latestRelease: URL
    /// Updates are only downloaded from addresses that start with this.
    var downloadPrefix: String

    static let gitHub = UpdateSource(
        latestRelease: URL(string: "https://api.github.com/repos/breidenbach0/DockFolder/releases/latest")!,
        downloadPrefix: "https://github.com/breidenbach0/DockFolder/releases/download/")
}

/// Puts a downloaded DockFolder in place of the one running.
struct UpdateInstaller {
    enum Failure: LocalizedError, Equatable {
        case damaged
        case notDockFolder
        case wrongVersion(String)
        case cantReplace(String)
        case tool(String)

        var errorDescription: String? {
            switch self {
            case .damaged:
                return "The download is damaged: it doesn’t match the release on GitHub."
            case .notDockFolder:
                return "The download doesn’t contain DockFolder."
            case .wrongVersion(let version):
                return "The download contains DockFolder \(version), not the version the release is for."
            case .cantReplace(let message):
                return "Couldn’t replace DockFolder: \(message) You can download the update from GitHub instead."
            case .tool(let message):
                return message
            }
        }
    }

    /// The DockFolder app's bundle ID. An update must have the same.
    var bundleID = "dev.local.dockfolder"

    /// Checks the zipped app against `sha256`, unpacks it, checks it's DockFolder `version` with
    /// its signature intact, and swaps it in for `app`. `app` stays as it was if anything fails.
    func install(archive: URL, sha256: String?, version: AppVersion, over app: URL) throws {
        if let sha256, try Self.sha256(of: archive) != sha256.lowercased() { throw Failure.damaged }

        let fileManager = FileManager.default
        let unpacked = fileManager.temporaryDirectory
            .appendingPathComponent("DockFolder-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: unpacked) }
        try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])

        let update = unpacked.appendingPathComponent("DockFolder.app", isDirectory: true)
        guard let info = NSDictionary(contentsOf: update.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID,
              info[AppRole.infoKey] as? String == "manager" else { throw Failure.notDockFolder }
        let shipped = info["CFBundleShortVersionString"] as? String ?? "?"
        guard AppVersion(shipped) == version else { throw Failure.wrongVersion(shipped) }
        try Self.run("/usr/bin/codesign", ["--verify", update.path])
        FolderFactory.removeQuarantine(from: update)

        // Copied next to the app first, so swapping it in is one quick step on the same disk.
        let staging: URL
        do {
            staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: app, create: true)
        } catch {
            throw Failure.cantReplace(error.localizedDescription)
        }
        defer { try? fileManager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(app.lastPathComponent, isDirectory: true)
        try Self.run("/usr/bin/ditto", [update.path, staged.path])
        do {
            _ = try fileManager.replaceItemAt(app, withItemAt: staged, backupItemName: nil, options: .usingNewMetadataOnly)
        } catch {
            throw Failure.cantReplace(error.localizedDescription)
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a command-line tool, and throws what it printed if it fails.
    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = URL(fileURLWithPath: tool).lastPathComponent
            throw Failure.tool("\(name) failed: \(text.isEmpty ? "exit status \(process.terminationStatus)" : text)")
        }
    }
}

/// Looks for a newer DockFolder on GitHub when the window opens and once a day, and installs it:
/// downloads it, swaps it in for this copy and starts it, and the new copy then updates the folders.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        /// Nothing to show.
        case idle
        /// Checking, because the user asked to.
        case checking
        case available(Release)
        case installing(Release, step: String)
        /// The new version is in place, but couldn't be started; opening DockFolder again does it.
        case needsRestart(AppVersion)
        /// Started again after updating itself, and updating the folders.
        case updatingFolders(AppVersion)
        case updated(AppVersion)
        case failed(Release?, String)
    }

    static let log = Logger(subsystem: "dev.local.dockfolder", category: "updates")
    static let checksAutomaticallyKey = "DockFolderChecksForUpdates"
    static let lastCheckKey = "DockFolderLastUpdateCheck"
    /// Set just before starting the new version, so it updates the folders.
    static let updateFoldersKey = "DockFolderUpdateFoldersOnLaunch"

    @Published private(set) var state = State.idle
    /// A check the user asked for found nothing newer.
    @Published var isShowingUpToDate = false

    let currentVersion: AppVersion?
    let source: UpdateSource
    private let app: URL
    private let session: URLSession
    private let defaults: UserDefaults
    private let relaunch: @MainActor (URL) -> Bool
    private var timer: Timer?

    init(source: UpdateSource = .gitHub, app: URL = Bundle.main.bundleURL,
         currentVersion: AppVersion? = .current, session: URLSession = .shared,
         defaults: UserDefaults = .standard, relaunch: @escaping @MainActor (URL) -> Bool = Updater.relaunch(_:)) {
        self.source = source
        self.app = app
        self.currentVersion = currentVersion
        self.session = session
        self.defaults = defaults
        self.relaunch = relaunch
    }

    var checksAutomatically: Bool {
        get { defaults.object(forKey: Self.checksAutomaticallyKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.checksAutomaticallyKey)
        }
    }

    /// Whether this copy can replace itself: an app in a folder it may write to, not one run
    /// from the disk image or from the read-only spot macOS moves quarantined apps to.
    var canInstall: Bool {
        app.pathExtension == "app"
            && !app.path.contains("/AppTranslocation/")
            && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    var isBusy: Bool {
        switch state {
        case .checking, .installing, .updatingFolders: return true
        default: return false
        }
    }

    /// Checks now, unless that was done in the last hour, and then once a day.
    func start() {
        checkIfDue(after: 3600)
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue(after: 24 * 3600) }
        }
    }

    private func checkIfDue(after interval: TimeInterval) {
        guard checksAutomatically, state == .idle else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= interval else { return }
        Task { await check(userInitiated: false) }
    }

    /// Looks for a newer release. A check the user asked for shows that it's checking, and says
    /// so when there's nothing newer or the check fails; other checks only show a newer release.
    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        if userInitiated { state = .checking }
        defaults.set(Date(), forKey: Self.lastCheckKey)
        do {
            if let release = try await latestRelease(), let current = currentVersion, release.version > current {
                Self.log.notice("DockFolder \(release.version, privacy: .public) is available")
                state = .available(release)
            } else {
                if state == .checking { state = .idle }
                if userInitiated { isShowingUpToDate = true }
            }
        } catch {
            Self.log.error("checking for updates failed: \(error.localizedDescription, privacy: .public)")
            if userInitiated {
                state = .failed(nil, "Couldn’t check for updates: \(error.localizedDescription)")
            }
        }
    }

    private func latestRelease() async throws -> Release? {
        var request = URLRequest(url: source.latestRelease, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return nil }   // no release yet
            guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        }
        return Release(gitHubJSON: data)
    }

    /// Downloads the release, swaps it in for this copy of DockFolder and starts it.
    func install(_ release: Release) async {
        guard !isBusy else { return }
        guard canInstall, let archive = release.archive else {
            NSWorkspace.shared.open(release.page)
            return
        }
        guard archive.absoluteString.hasPrefix(source.downloadPrefix) else {
            state = .failed(release, "The update isn’t where DockFolder’s releases are, so it wasn’t downloaded.")
            return
        }
        state = .installing(release, step: "Downloading…")
        do {
            let (download, response) = try await session.download(from: archive)
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("DockFolder-\(release.version)-\(UUID().uuidString).zip")
            try FileManager.default.moveItem(at: download, to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }

            state = .installing(release, step: "Installing…")
            let app = app
            try await Task.detached(priority: .userInitiated) {
                try UpdateInstaller().install(archive: file, sha256: release.sha256, version: release.version, over: app)
            }.value
        } catch {
            Self.log.error("installing \(release.version, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(release, error.localizedDescription)
            return
        }

        Self.log.notice("installed DockFolder \(release.version, privacy: .public); starting it")
        defaults.set(true, forKey: Self.updateFoldersKey)
        if !relaunch(app) { state = .needsRestart(release.version) }
    }

    /// After DockFolder updated itself and started again: brings every folder up to this version.
    func finishUpdate(library: FolderLibrary) async {
        guard defaults.bool(forKey: Self.updateFoldersKey) else { return }
        defaults.removeObject(forKey: Self.updateFoldersKey)
        guard let version = currentVersion else { return }
        state = .updatingFolders(version)
        let failed = await library.updateOutdatedFolders()
        state = failed.isEmpty
            ? .updated(version)
            : .failed(nil, "DockFolder \(version) is installed, but \(failed.joined(separator: ", ")) couldn’t be updated. Select it and click Update to try again.")
    }

    /// Closes the card about an update, until the next check finds something.
    func dismiss() {
        if !isBusy { state = .idle }
    }

    /// Starts DockFolder again from `app` once this copy has quit, and quits.
    /// Returns false, without quitting, if the new copy can't be started.
    static func relaunch(_ app: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", relaunchScript, "sh", String(ProcessInfo.processInfo.processIdentifier),
                             "/usr/bin/open", app.path]
        do {
            try process.run()
        } catch {
            log.error("couldn't start the new DockFolder: \(error.localizedDescription, privacy: .public)")
            return false
        }
        NSApp.terminate(nil)
        return true
    }

    /// Waits up to 20 seconds for process $1 to end, then runs $2 with $3.
    nonisolated static let relaunchScript = """
        i=0
        while /bin/kill -0 "$1" 2>/dev/null && [ "$i" -lt 100 ]; do /bin/sleep 0.2; i=$((i + 1)); done
        "$2" "$3"
        """
}
