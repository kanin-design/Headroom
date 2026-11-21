// swift-tools-version: 6.2
import PackageDescription

// A month's budget as a sunburst: the same parts as a disk, on data that isn't one.
let package = Package(
    name: "Budget",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(name: "Budget", dependencies: [.product(name: "SunburstKit", package: "SunburstKit")],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
