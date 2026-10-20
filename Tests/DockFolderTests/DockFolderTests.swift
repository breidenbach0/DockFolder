import AppKit
import XCTest
@testable import DockFolder

final class DockGeometryTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = NSSize(width: 300, height: 200)

    func testBottomDockOpensAboveTheDockCenteredOnTheIcon() {
        let dock = DockGeometry(edge: .bottom, tileSize: 48)
        let visible = NSRect(x: 0, y: 70, width: 1440, height: 805)   // Dock takes the bottom 70pt
        let frame = dock.panelFrame(size: size, anchor: NSPoint(x: 700, y: 30),
                                    screenFrame: screen, visibleFrame: visible)
        XCTAssertEqual(frame.midX, 700)
        XCTAssertEqual(frame.minY, 78)
    }

    func testAutoHiddenDockStillLeavesRoomForTheIcons() {
        let dock = DockGeometry(edge: .bottom, tileSize: 48)
        let visible = NSRect(x: 0, y: 4, width: 1440, height: 871)    // auto-hide: 4pt strip
        let frame = dock.panelFrame(size: size, anchor: NSPoint(x: 700, y: 30),
                                    screenFrame: screen, visibleFrame: visible)
        XCTAssertEqual(frame.minY, 68)   // 48pt icon + 12 + 8 gap
    }

    func testPanelNearTheScreenCornerStaysOnScreen() {
        let dock = DockGeometry(edge: .bottom, tileSize: 48)
        let visible = NSRect(x: 0, y: 70, width: 1440, height: 805)
        let frame = dock.panelFrame(size: size, anchor: NSPoint(x: 10, y: 30),
                                    screenFrame: screen, visibleFrame: visible)
        XCTAssertEqual(frame.minX, 8)
    }

    func testRightDockOpensToTheLeftOfTheDock() {
        let dock = DockGeometry(edge: .right, tileSize: 48)
        let visible = NSRect(x: 0, y: 0, width: 1370, height: 875)
        let frame = dock.panelFrame(size: size, anchor: NSPoint(x: 1410, y: 450),
                                    screenFrame: screen, visibleFrame: visible)
        XCTAssertEqual(frame.maxX, 1362)
        XCTAssertEqual(frame.midY, 450)
    }

    func testPointerIsOverTheDockOnlyNearItsEdge() {
        let dock = DockGeometry(edge: .bottom, tileSize: 48)
        XCTAssertTrue(dock.isNearDock(NSPoint(x: 700, y: 30), screenFrame: screen))
        XCTAssertFalse(dock.isNearDock(NSPoint(x: 700, y: 500), screenFrame: screen))
    }
}

final class FolderLayoutTests: XCTestCase {
    func testPagesHoldNineAppsEachInThreeColumns() {
        XCTAssertEqual(FolderLayout.columns(for: 27, style: .pages), 3)
        XCTAssertEqual(FolderLayout.pageCount(for: 9), 1)
        XCTAssertEqual(FolderLayout.pageCount(for: 10), 2)
        XCTAssertEqual(FolderLayout.pageCount(for: 27), 3)
        XCTAssertEqual(Array(1...20).chunked(into: 9).map(\.count), [9, 9, 2])
    }

    func testOnePageFitsItsAppsWhileMorePagesKeepAFullPage() {
        XCTAssertEqual(FolderLayout.visibleRows(for: 4, style: .pages), 2)
        XCTAssertEqual(FolderLayout.visibleRows(for: 10, style: .pages), 3)
        XCTAssertFalse(FolderLayout.showsPageDots(for: 9, style: .pages))
        XCTAssertTrue(FolderLayout.showsPageDots(for: 10, style: .pages))
        // Turning to a half-empty last page doesn't resize the panel.
        XCTAssertEqual(FolderLayout.panelSize(itemCount: 10, style: .pages),
                       FolderLayout.panelSize(itemCount: 27, style: .pages))
    }

    func testTheGridWidensToSixColumnsThenGrowsToSixRows() {
        XCTAssertEqual(FolderLayout.columns(for: 2, style: .grid), 3)
        XCTAssertEqual(FolderLayout.columns(for: 5, style: .grid), 5)
        XCTAssertEqual(FolderLayout.columns(for: 36, style: .grid), 6)
        XCTAssertEqual(FolderLayout.visibleRows(for: 13, style: .grid), 3)
        XCTAssertEqual(FolderLayout.visibleRows(for: 36, style: .grid), 6)
        XCTAssertFalse(FolderLayout.showsPageDots(for: 36, style: .grid))
    }

    func testEmptyFolderStillHasOneRow() {
        XCTAssertEqual(FolderLayout.visibleRows(for: 0, style: .pages), 1)
        XCTAssertEqual(FolderLayout.visibleRows(for: 0, style: .grid), 1)
    }
}

final class FolderStoreTests: XCTestCase {
    private let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DockFolderTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    func testAddingTheSameAppTwiceKeepsOneEntry() {
        let store = FolderStore(directory: makeDirectory())
        store.add([calculator])
        store.add([calculator])
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.bundleID, "com.apple.calculator")
    }

    @MainActor
    func testAppsSurviveARelaunch() {
        let directory = makeDirectory()
        FolderStore(directory: directory).add([calculator])
        let reopened = FolderStore(directory: directory)
        XCTAssertEqual(reopened.items.map(\.path), [calculator.path])
    }

    @MainActor
    func testUnreadableDataIsKeptAsideNotOverwritten() throws {
        let directory = makeDirectory()
        let store = FolderStore(directory: directory)
        try Data("not json".utf8).write(to: store.dataURL)

        let reopened = FolderStore(directory: directory)
        XCTAssertTrue(reopened.items.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.contains(".unreadable-") })
    }

    @MainActor
    func testColourSurvivesARelaunch() {
        let directory = makeDirectory()
        FolderStore(directory: directory).setTint(.purple)
        XCTAssertEqual(FolderStore(directory: directory).tint, .purple)
    }

    @MainActor
    func testACustomColourSurvivesARelaunch() {
        let directory = makeDirectory()
        FolderStore(directory: directory).setTint(FolderTint(savedName: "#1E90FF"))
        XCTAssertEqual(FolderStore(directory: directory).tint.savedName, "#1E90FF")
    }

    @MainActor
    func testFilesFromBeforeColoursStillLoad() throws {
        let directory = makeDirectory()
        let store = FolderStore(name: "Old", bundleID: "dev.local.dockfolder.old", directory: directory)
        let saved = #"{"items":[{"id":"07EA27EC-9FE7-4F96-A8E7-2CA200195585","path":"\#(calculator.path)"}],"version":1}"#
        try Data(saved.utf8).write(to: store.dataURL)

        let reopened = FolderStore(name: "Old", bundleID: "dev.local.dockfolder.old", directory: directory)
        XCTAssertEqual(reopened.items.map(\.path), [calculator.path])
        XCTAssertEqual(reopened.tint, .clear)
    }

    @MainActor
    func testPagesHoldTwentySevenAppsAndTurnAwayTheRest() {
        let store = FolderStore(name: "Many", bundleID: "dev.local.dockfolder.many", directory: makeDirectory())
        let apps = (1...30).map { URL(fileURLWithPath: "/Applications/Test App \($0).app") }
        XCTAssertEqual(store.add(apps), 3)
        XCTAssertEqual(store.items.count, 27)
        XCTAssertTrue(store.isFull)
    }

    @MainActor
    func testAFolderOnlySwitchesToALayoutItsAppsFit() {
        let store = FolderStore(name: "Many", bundleID: "dev.local.dockfolder.many", directory: makeDirectory())
        XCTAssertTrue(store.setStyle(.grid))
        store.add((1...30).map { URL(fileURLWithPath: "/Applications/Test App \($0).app") })
        XCTAssertEqual(store.items.count, 30)
        XCTAssertFalse(store.setStyle(.pages), "30 apps don't fit on 3 pages of 9")
        XCTAssertEqual(store.style, .grid)
    }

    @MainActor
    func testLayoutSurvivesARelaunchAndOldFilesGetOneThatFits() throws {
        let directory = makeDirectory()
        FolderStore(directory: directory).setStyle(.grid)
        XCTAssertEqual(FolderStore(directory: directory).style, .grid)

        // Saved before folders had a layout, with more apps than pages hold.
        let store = FolderStore(name: "Old", bundleID: "dev.local.dockfolder.old-many", directory: directory)
        let items = (1...30).map { #"{"id":"\#(UUID().uuidString)","path":"/Applications/Test App \#($0).app"}"# }
        try Data(#"{"items":[\#(items.joined(separator: ","))],"version":1}"#.utf8).write(to: store.dataURL)
        let reopened = FolderStore(name: "Old", bundleID: "dev.local.dockfolder.old-many", directory: directory)
        XCTAssertEqual(reopened.style, .grid)
        XCTAssertEqual(reopened.items.count, 30)
    }

    @MainActor
    func testANewFolderStartsWithExactlyItsChosenAppsAndColour() {
        let directory = makeDirectory()
        let leftover = FolderStore(name: "Work", bundleID: "dev.local.dockfolder.work", directory: directory)
        leftover.add([URL(fileURLWithPath: "/System/Applications/Notes.app")])   // from an older folder of the same name

        FolderStore(name: "Work", bundleID: "dev.local.dockfolder.work", directory: directory)
            .reset(apps: [calculator, calculator], tint: .orange)

        let reopened = FolderStore(name: "Work", bundleID: "dev.local.dockfolder.work", directory: directory)
        XCTAssertEqual(reopened.items.map(\.path), [calculator.path])
        XCTAssertEqual(reopened.tint, .orange)
    }

    @MainActor
    func testEditsFromTheOtherProcessAreKept() {
        // The running folder and the DockFolder window each have a store on the same file.
        let directory = makeDirectory()
        let folder = FolderStore(name: "Tools", bundleID: "dev.local.dockfolder.tools", directory: directory)
        let window = FolderStore(name: "Tools", bundleID: "dev.local.dockfolder.tools", directory: directory)

        window.add([calculator])
        folder.setTint(.green)   // reads the window's change first, so it isn't overwritten
        XCTAssertEqual(folder.items.map(\.path), [calculator.path])

        window.reloadIfChangedOnDisk()
        XCTAssertEqual(window.tint, .green)
    }
}

final class FolderTintTests: XCTestCase {
    func testUnknownOrMissingColoursFallBackToClearGlass() {
        XCTAssertEqual(FolderTint(savedName: "blue"), .blue)
        XCTAssertEqual(FolderTint(savedName: nil), .clear)
        XCTAssertEqual(FolderTint(savedName: "chartreuse"), .clear)
        XCTAssertEqual(FolderTint(savedName: "#GG0000"), .clear)
        XCTAssertEqual(FolderTint(savedName: "#FFF"), .clear)
    }

    func testCustomColoursAreSavedAsHex() {
        let orange = FolderTint(savedName: "#FF8800")
        XCTAssertEqual(orange, .custom(red: 1, green: 136.0 / 255, blue: 0))
        XCTAssertEqual(orange.savedName, "#FF8800")
        XCTAssertTrue(orange.isCustom)
    }

    func testAPickedColourComesBackTheSameFromTheFile() {
        let picked = FolderTint(color: NSColor(srgbRed: 0.5, green: 0.25, blue: 0.75, alpha: 1))
        XCTAssertEqual(picked.savedName, "#8040BF")
        XCTAssertEqual(FolderTint(savedName: picked.savedName), picked)
    }
}

final class FolderFactoryTests: XCTestCase {
    func testBundleIDsFollowTheFolderName() {
        XCTAssertEqual(FolderFactory.bundleID(for: "Design", avoiding: []), "dev.local.dockfolder.design")
        XCTAssertEqual(FolderFactory.bundleID(for: "My Apps 2", avoiding: []), "dev.local.dockfolder.my-apps-2")
        XCTAssertEqual(FolderFactory.bundleID(for: "Café & Co.", avoiding: []), "dev.local.dockfolder.cafe-co")
        XCTAssertEqual(FolderFactory.bundleID(for: "🎨", avoiding: []), "dev.local.dockfolder.folder")
    }

    func testBundleIDsDontCollide() {
        let taken: Set = ["dev.local.dockfolder.design", "dev.local.dockfolder.design-2"]
        XCTAssertEqual(FolderFactory.bundleID(for: "Design", avoiding: taken), "dev.local.dockfolder.design-3")
    }

    func testNamesThatCantBeFileNamesAreRefused() throws {
        XCTAssertThrowsError(try FolderFactory.validatedName("   "))
        XCTAssertThrowsError(try FolderFactory.validatedName("A/B"))
        XCTAssertThrowsError(try FolderFactory.validatedName(".hidden"))
        XCTAssertEqual(try FolderFactory.validatedName("  Work  "), "Work")
    }

    func testAFolderGetsItsOwnNameIDAndSignature() throws {
        let root = makeTemporaryDirectory()
        let factory = FolderFactory(template: try makeTemplate(in: root),
                                    foldersDirectory: root.appendingPathComponent("Dock Folders"))
        let plan = try factory.plan(name: "Work", existingBundleIDs: [])
        try factory.build(plan)

        let info = try XCTUnwrap(NSDictionary(contentsOf: plan.url.appendingPathComponent("Contents/Info.plist")))
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "dev.local.dockfolder.work")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Work")
        XCTAssertNil(info[AppRole.infoKey], "a copy must run as a folder, not as the DockFolder window")
        XCTAssertEqual(info[FolderFactory.buildKey] as? String, "build-1")
        XCTAssertEqual(try run("/usr/bin/codesign", "--verify", plan.url.path), 0)
        XCTAssertThrowsError(try factory.plan(name: "Work", existingBundleIDs: []))
    }

    func testFoldersDontInheritTheDownloadQuarantine() throws {
        let root = makeTemporaryDirectory()
        let template = try makeTemplate(in: root)
        let flag = Array("0081;00000000;Safari;".utf8)
        for path in [template.path, template.appendingPathComponent("Contents/MacOS/DockFolder").path] {
            XCTAssertEqual(setxattr(path, "com.apple.quarantine", flag, flag.count, 0, 0), 0)
        }
        let factory = FolderFactory(template: template, foldersDirectory: root.appendingPathComponent("Dock Folders"))
        let plan = try factory.plan(name: "Work", existingBundleIDs: [])
        try factory.build(plan)

        for path in [plan.url.path, plan.url.appendingPathComponent("Contents/MacOS/DockFolder").path] {
            XCTAssertEqual(getxattr(path, "com.apple.quarantine", nil, 0, 0, 0), -1, path)
        }
    }

    func testRebuildingKeepsTheFolderButTakesTheNewBuild() throws {
        let root = makeTemporaryDirectory()
        let template = try makeTemplate(in: root)
        let factory = FolderFactory(template: template, foldersDirectory: root.appendingPathComponent("Dock Folders"))
        let plan = try factory.plan(name: "Work", existingBundleIDs: [])
        try factory.build(plan)

        try setBuildStamp("build-2", of: template)
        try factory.rebuild(at: plan.url, name: plan.name, bundleID: plan.bundleID)

        XCTAssertEqual(FolderFactory.buildStamp(ofApp: plan.url), "build-2")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plan.url.appendingPathComponent("Contents/Info.plist")))
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, plan.bundleID)
        XCTAssertEqual(try run("/usr/bin/codesign", "--verify", plan.url.path), 0)
    }

    func testRenamingKeepsTheFolderButChangesItsName() throws {
        let root = makeTemporaryDirectory()
        let factory = FolderFactory(template: try makeTemplate(in: root),
                                    foldersDirectory: root.appendingPathComponent("Dock Folders"))
        let plan = try factory.plan(name: "Work", existingBundleIDs: [])
        try factory.build(plan)

        let renamed = try factory.rename(at: plan.url, bundleID: plan.bundleID, to: "Projects")

        XCTAssertEqual(renamed.lastPathComponent, "Projects.app")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.url.path))
        let info = try XCTUnwrap(NSDictionary(contentsOf: renamed.appendingPathComponent("Contents/Info.plist")))
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Projects")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, plan.bundleID, "the bundle ID is what keeps its apps")
        XCTAssertEqual(try run("/usr/bin/codesign", "--verify", renamed.path), 0)
    }

    func testRenamingCanChangeJustTheCase() throws {
        let root = makeTemporaryDirectory()
        let foldersDirectory = root.appendingPathComponent("Dock Folders")
        let factory = FolderFactory(template: try makeTemplate(in: root), foldersDirectory: foldersDirectory)
        let plan = try factory.plan(name: "Work", existingBundleIDs: [])
        try factory.build(plan)

        _ = try factory.rename(at: plan.url, bundleID: plan.bundleID, to: "work")

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: foldersDirectory.path), ["work.app"])
    }

    func testRenamingOntoAnotherFolderIsRefused() throws {
        let root = makeTemporaryDirectory()
        let factory = FolderFactory(template: try makeTemplate(in: root),
                                    foldersDirectory: root.appendingPathComponent("Dock Folders"))
        let work = try factory.plan(name: "Work", existingBundleIDs: [])
        try factory.build(work)
        try factory.build(factory.plan(name: "Play", existingBundleIDs: [work.bundleID]))

        XCTAssertThrowsError(try factory.rename(at: work.url, bundleID: work.bundleID, to: "Play"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.url.path))
    }

    @MainActor
    func testTheListShowsFoldersButNotTheDockFolderAppItself() throws {
        let root = makeTemporaryDirectory()
        let template = try makeTemplate(in: root)
        let foldersDirectory = root.appendingPathComponent("Dock Folders")
        let factory = FolderFactory(template: template, foldersDirectory: foldersDirectory)
        let plan = try factory.plan(name: "Work", existingBundleIDs: [])
        try factory.build(plan)
        try FileManager.default.copyItem(at: template, to: foldersDirectory.appendingPathComponent("DockFolder.app"))

        let library = FolderLibrary(template: template, foldersDirectory: foldersDirectory, dataDirectory: root)
        XCTAssertEqual(library.folders.map(\.name), ["Work"])
        XCTAssertFalse(library.folders[0].isOutdated)

        try setBuildStamp("build-2", of: template)
        let newer = FolderLibrary(template: template, foldersDirectory: foldersDirectory, dataDirectory: root)
        XCTAssertTrue(newer.folders[0].isOutdated)
    }

    @MainActor
    func testAStrayCopyWithTheSameBundleIDIsShownOnce() throws {
        let root = makeTemporaryDirectory()
        let template = try makeTemplate(in: root)
        let foldersDirectory = root.appendingPathComponent("Dock Folders")
        let factory = FolderFactory(template: template, foldersDirectory: foldersDirectory)
        let plan = try factory.plan(name: "Work", existingBundleIDs: [])
        try factory.build(plan)
        let copy = foldersDirectory.appendingPathComponent("Work copy.app")
        try FileManager.default.copyItem(at: plan.url, to: copy)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: copy.path)

        let library = FolderLibrary(template: template, foldersDirectory: foldersDirectory, dataDirectory: root)
        XCTAssertEqual(library.folders.count, 1)
        XCTAssertEqual(library.folders.first?.url.lastPathComponent, "Work copy.app", "the newest copy")
        // Deleting one copy checks this before it touches the saved apps they share.
        XCTAssertEqual(FolderLibrary.folderApps(withBundleID: plan.bundleID, in: foldersDirectory).count, 2)
    }

    /// A stand-in for DockFolder.app, with a real (tiny) executable so codesign accepts it.
    private func makeTemplate(in directory: URL) throws -> URL {
        let app = directory.appendingPathComponent("DockFolder.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("DockFolder").path)
        let info: [String: Any] = [
            "CFBundleExecutable": "DockFolder",
            "CFBundleIdentifier": "dev.local.dockfolder",
            "CFBundleName": "DockFolder",
            "CFBundlePackageType": "APPL",
            AppRole.infoKey: "manager",
            FolderFactory.buildKey: "build-1",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    private func setBuildStamp(_ stamp: String, of app: URL) throws {
        let url = app.appendingPathComponent("Contents/Info.plist")
        let info = try XCTUnwrap(NSMutableDictionary(contentsOf: url))
        info[FolderFactory.buildKey] = stamp
        try info.write(to: url)
    }

    private func run(_ tool: String, _ arguments: String...) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

final class PageSwipeTests: XCTestCase {
    /// A scroll event as a trackpad (precise) or a mouse wheel sends it.
    private func scroll(dx: Int32, dy: Int32 = 0, phase: Int64 = 0, momentum: Int64 = 0, precise: Bool = true) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2,
                         wheel1: dy, wheel2: dx, wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)          // 1 began, 2 changed, 4 ended
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        if precise {
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        }
        cg.location = CGPoint(x: 50, y: 50)
        return NSEvent(cgEvent: cg)!
    }

    @MainActor
    private func catcher() -> SwipeCatcherView {
        SwipeCatcherView(frame: NSRect(x: 0, y: 0, width: 100_000, height: 100_000))
    }

    @MainActor
    func testASidewaysSwipeMovesThePagesAndEndsWithItsSpeed() {
        let view = catcher()
        var moved: CGFloat = 0
        var speed: CGFloat?
        view.onSwipe = { moved += $0 }
        view.onSwipeEnd = { speed = $0 }

        XCTAssertNil(view.handleScroll(scroll(dx: -2, phase: 1)))
        for _ in 0..<5 { XCTAssertNil(view.handleScroll(scroll(dx: -10, phase: 2))) }
        XCTAssertNil(view.handleScroll(scroll(dx: 0, phase: 4)))

        XCTAssertEqual(moved, -52)
        XCTAssertEqual(speed, -10)
        XCTAssertNil(view.handleScroll(scroll(dx: -20, momentum: 2)), "the glide after a swipe is used up too")
    }

    @MainActor
    func testUpAndDownScrollsAreLeftAlone() {
        let view = catcher()
        var moved = false
        view.onSwipe = { _ in moved = true }
        XCTAssertNotNil(view.handleScroll(scroll(dx: 0, dy: -10, phase: 1)))
        XCTAssertNotNil(view.handleScroll(scroll(dx: -3, dy: -10, phase: 2)))
        XCTAssertFalse(moved)
    }

    @MainActor
    func testEachMouseWheelNotchTurnsOnePage() {
        let view = catcher()
        var steps: [Int] = []
        view.onStep = { steps.append($0) }
        XCTAssertNil(view.handleScroll(scroll(dx: -1, precise: false)))
        XCTAssertNil(view.handleScroll(scroll(dx: 1, precise: false)))
        XCTAssertEqual(steps, [1, -1])
    }
}

final class DockPreferencesTests: XCTestCase {
    func testTilesSavedByTheDockAndByDefaultsWriteBothResolve() {
        let savedByDock: [String: Any] = ["tile-data": ["file-data": [
            "_CFURLString": "file:///Users/me/Applications/Dock%20Folders/Design.app/", "_CFURLStringType": 15]]]
        let savedByDefaults: [String: Any] = ["tile-data": ["file-data": [
            "_CFURLString": "/Users/me/Applications/Dock Folders/Design.app", "_CFURLStringType": 0]]]
        XCTAssertEqual(DockPreferences.path(ofTile: savedByDock), "/Users/me/Applications/Dock Folders/Design.app")
        XCTAssertEqual(DockPreferences.path(ofTile: savedByDefaults), "/Users/me/Applications/Dock Folders/Design.app")
    }

    func testARenamedFolderKeepsItsPlaceInTheDock() {
        func tile(_ url: URL) -> [String: Any] {
            ["tile-data": ["file-data": ["_CFURLString": url.absoluteString, "_CFURLStringType": 15],
                           "file-label": url.deletingPathExtension().lastPathComponent,
                           "book": Data([1, 2, 3])]]
        }
        let safari = URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true)
        let design = URL(fileURLWithPath: "/Users/me/Applications/Dock Folders/Design.app", isDirectory: true)
        let tools = URL(fileURLWithPath: "/Users/me/Applications/Dock Folders/Tools.app", isDirectory: true)
        let mail = URL(fileURLWithPath: "/System/Applications/Mail.app", isDirectory: true)

        let updated = DockPreferences.replacingTile(for: design, with: tools, in: [tile(safari), tile(design), tile(mail)])

        XCTAssertEqual(updated.compactMap(DockPreferences.path(ofTile:)), [safari.path, tools.path, mail.path])
        let renamed = updated[1]["tile-data"] as? [String: Any]
        XCTAssertEqual(renamed?["file-label"] as? String, "Tools")
        XCTAssertNil(renamed?["book"], "the old bookmark points at the old app")
        XCTAssertNotNil((updated[0]["tile-data"] as? [String: Any])?["book"])
    }
}

final class FolderIconTests: XCTestCase {
    func testAppIconsetHasEverySizeIconutilNeeds() throws {
        let iconset = makeTemporaryDirectory().appendingPathComponent("AppIcon.iconset")
        try FolderIcon.writeAppIconset(to: iconset)
        let files = try FileManager.default.contentsOfDirectory(atPath: iconset.path)
        XCTAssertEqual(files.count, 10)
        XCTAssertTrue(files.contains("icon_512x512@2x.png"))
    }
}

extension XCTestCase {
    func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DockFolderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
