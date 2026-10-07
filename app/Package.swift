// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GhosttySidebar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GhosttySidebar", path: "Sources/GhosttySidebar")
    ]
)
