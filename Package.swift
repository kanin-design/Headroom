// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Headroom",
            path: "Sources/Headroom",
            exclude: ["Render/Shaders.metal"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked"], .when(configuration: .release)),
            ]
        )
    ]
)
