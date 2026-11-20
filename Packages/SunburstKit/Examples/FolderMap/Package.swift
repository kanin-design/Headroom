// swift-tools-version: 6.2
import Foundation
import PackageDescription

// A small Mac app that shows a folder, or a made-up sample, as a sunburst: `swift run` in this folder.

// SwiftPM names a package used by path after its folder, whatever that folder is called where it was cloned.
let sunburstKit = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().lastPathComponent

let package = Package(
    name: "FolderMap",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(name: "FolderMap", dependencies: [
            .product(name: "SunburstKit", package: sunburstKit),
            .product(name: "SunburstAgents", package: sunburstKit),
        ]),
    ]
)
