import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Dragging apps into a folder. (Moving apps within a folder doesn't drag anything: see Rearrangement.)
enum FolderDrag {
    /// An app dragged from the Dock shown under a folder in the DockFolder window.
    static let dockAppType = UTType(exportedAs: "dev.local.dockfolder.dock-app")

    /// Everything a folder takes drops of.
    static let dropTypes: [UTType] = [dockAppType, .fileURL]

    /// What drags and drops do, in Console under the subsystem dev.local.dockfolder.
    static let log = Logger(subsystem: "dev.local.dockfolder", category: "drops")

    static func provider(type: UTType, payload: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(Data(payload.utf8), nil)
            return nil
        }
        return provider
    }
}

/// Apps dropped on a folder: from the Finder, or, in the DockFolder window, from the Dock shown
/// under it. One target for the whole folder: SwiftUI's drop targets take every drag over them,
/// whatever it carries, so a second one inside would hide drops from this one.
struct FolderDropDelegate: DropDelegate {
    let store: FolderStore
    @Binding var isTargeted: Bool
    /// Moves an app out of the Dock into the folder. Only in the DockFolder window.
    var onDockApp: ((URL) -> Bool)?

    func validateDrop(info: DropInfo) -> Bool {
        (onDockApp != nil && info.hasItemsConforming(to: [FolderDrag.dockAppType]))
            || info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        if let onDockApp, let provider = info.itemProviders(for: [FolderDrag.dockAppType]).first {
            provider.loadDataRepresentation(forTypeIdentifier: FolderDrag.dockAppType.identifier) { data, _ in
                guard let data, let path = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    FolderDrag.log.notice("app from the window's Dock: \(path, privacy: .public)")
                    if !onDockApp(URL(fileURLWithPath: path)) { NSSound.beep() }   // the folder is full
                }
            }
            return true
        }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        FolderDrag.log.notice("dropped \(providers.count) file(s) on the folder")
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension == "app" else { return }
                DispatchQueue.main.async {
                    FolderDrag.log.notice("adding dropped app \(url.path, privacy: .public)")
                    if store.add([url]) > 0 { NSSound.beep() }   // the folder is full
                }
            }
        }
        return true
    }
}

/// SwiftUI says nothing when a drag ends away from a drop target, so this watches the mouse
/// button and reports when it's let go.
@MainActor
final class DragEndWatcher: NSObject, ObservableObject {
    private var onEnd: (() -> Void)?

    func watch(_ onEnd: @escaping () -> Void) {
        self.onEnd = onEnd
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        perform(#selector(check), with: nil, afterDelay: 0.1, inModes: [.common])
    }

    @objc private func check() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            let onEnd = self.onEnd
            self.onEnd = nil
            onEnd?()
        } else {
            perform(#selector(check), with: nil, afterDelay: 0.1, inModes: [.common])
        }
    }
}

/// The Dock never hands its icons to other apps: an app dragged out of the Dock shows "Remove"
/// and leaves the Dock when let go, and that's all. So while the folder is open, this watches
/// the mouse for a drag that starts on the Dock and ends over the folder, and the app the Dock
/// then removes goes in the folder.
@MainActor
final class DockDragWatcher: NSObject {
    /// Where the folder's glass is on screen.
    var folderFrame: () -> NSRect = { .zero }
    /// True while an app from the Dock is held over the folder.
    var onHover: (Bool) -> Void = { _ in }
    /// The app the Dock removed after it was let go over the folder.
    var onDrop: (URL) -> Void = { _ in }

    private var monitor: Any?
    /// The Dock's apps when the current drag began on the Dock, to tell which one it removes.
    private var dockAppsAtDragStart: [URL]?
    private var isHovering = false
    /// A drag from the Dock that ended over the folder, until the Dock removes the app.
    private var pendingDrop: (dockApps: [URL], giveUpAt: Date)?

    func start() {
        guard monitor == nil else { return }
        // Mouse events sent to other apps, such as the Dock, can be watched without any permission.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event.type) }
        }
    }

    /// Stops watching the mouse. An app already let go over the folder still goes in.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        dockAppsAtDragStart = nil
        setHovering(false)
    }

    private func handle(_ type: NSEvent.EventType) {
        let point = NSEvent.mouseLocation
        switch type {
        case .leftMouseDown:
            dockAppsAtDragStart = DockGeometry.isOverDock(point) ? DockPreferences.appURLs() : nil
        case .leftMouseDragged:
            guard dockAppsAtDragStart != nil else { return }
            setHovering(folderFrame().contains(point))
        case .leftMouseUp:
            guard let dockApps = dockAppsAtDragStart else { return }
            dockAppsAtDragStart = nil
            setHovering(false)
            guard folderFrame().contains(point) else { return }
            FolderDrag.log.notice("a drag from the Dock ended over the folder")
            pendingDrop = (dockApps, Date().addingTimeInterval(4))
            NSObject.cancelPreviousPerformRequests(withTarget: self)
            lookForRemovedApp()
        default:
            break
        }
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        onHover(hovering)
    }

    /// The Dock saves its apps a moment after it removes one, so look a few times.
    @objc private func lookForRemovedApp() {
        guard let pending = pendingDrop else { return }
        if let app = Self.removedApp(before: pending.dockApps, after: DockPreferences.appURLs()) {
            pendingDrop = nil
            FolderDrag.log.notice("the Dock removed \(app.path, privacy: .public)")
            onDrop(app)
        } else if Date() < pending.giveUpAt {
            perform(#selector(lookForRemovedApp), with: nil, afterDelay: 0.1, inModes: [.common])
        } else {
            pendingDrop = nil
            FolderDrag.log.notice("the Dock kept the app (let go before “Remove” showed?)")
        }
    }

    /// The first app in `before` that isn't in `after`.
    nonisolated static func removedApp(before: [URL], after: [URL]) -> URL? {
        let remaining = Set(after.map(\.standardizedFileURL.path))
        return before.first { !remaining.contains($0.standardizedFileURL.path) }
    }
}
