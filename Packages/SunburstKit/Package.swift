// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SunburstKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SunburstKit", targets: ["SunburstKit"]),
    ],
    targets: [
        .target(
            name: "SunburstKit",
            // Compiled when the app starts, from the source: the app copies it into its Resources (see README).
            exclude: ["Shaders.metal"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // The layout is generic over the host's tree. Cross-module optimisation lets the host's build specialise it
                // for its own tree, so it runs as fast as code written for that tree.
                .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked", "-cross-module-optimization"], .when(configuration: .release)),
            ]
        ),
        .testTarget(
            name: "SunburstKitTests",
            dependencies: ["SunburstKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
