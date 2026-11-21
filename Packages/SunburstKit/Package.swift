// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SunburstKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SunburstKit", targets: ["SunburstKit"]),
        // Optional: the door agents come in by, and tools for the chart. An app that doesn't want agents leaves it out.
        .library(name: "SunburstAgents", targets: ["SunburstAgents"]),
    ],
    targets: [
        .target(
            name: "SunburstKit",
            // The shaders' readable source. ShaderSource.swift builds it into the package (Scripts/embed-shaders.sh), so an app
            // needs no resources of its own.
            exclude: ["Shaders.metal"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "SunburstKitTests",
            dependencies: ["SunburstKit"],
            // What the kit drew before parts, for the snapshot tests to compare with.
            exclude: ["Snapshots/Baseline"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SunburstAgents",
            dependencies: ["SunburstKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SunburstAgentsTests",
            dependencies: ["SunburstAgents", "SunburstKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
