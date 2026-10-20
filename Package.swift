// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DockFolder",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "DockFolder"),
        .testTarget(name: "DockFolderTests", dependencies: ["DockFolder"]),
    ]
)
