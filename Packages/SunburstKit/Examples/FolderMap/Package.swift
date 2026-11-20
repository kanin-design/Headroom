// swift-tools-version: 6.2
import PackageDescription

// A small Mac app that shows a folder, or a made-up sample, as a sunburst: `swift run` in this folder.
let package = Package(
    name: "FolderMap",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(name: "FolderMap", dependencies: [
            .product(name: "SunburstKit", package: "SunburstKit"),
            .product(name: "SunburstAgents", package: "SunburstKit"),
        ]),
    ]
)
