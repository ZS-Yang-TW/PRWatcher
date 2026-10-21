// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PRWatcher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "PRWatcher", path: "Sources/PRWatcher")
    ]
)
