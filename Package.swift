// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v26)],
    dependencies: [
        // The disk map: its layout, drawing, motion and names.
        .package(path: "Packages/SunburstKit"),
    ],
    targets: [
        .executableTarget(
            name: "Headroom",
            dependencies: [.product(name: "SunburstKit", package: "SunburstKit"), .product(name: "SunburstAgents", package: "SunburstKit")],
            path: "Sources/Headroom",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked"], .when(configuration: .release)),
            ]
        ),
        .testTarget(
            name: "HeadroomTests",
            dependencies: ["Headroom"],
            path: "Tests/HeadroomTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
