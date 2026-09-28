// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LeonardApp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LeonardCore", targets: ["LeonardCore"]),
        .executable(name: "LeonardApp", targets: ["LeonardApp"]),
    ],
    targets: [
        .target(
            name: "LeonardCore",
            path: "Sources/LeonardCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "LeonardApp",
            dependencies: ["LeonardCore"],
            path: "Sources/LeonardApp"
        ),
        .testTarget(
            name: "LeonardCoreTests",
            dependencies: ["LeonardCore"],
            path: "Tests/LeonardCoreTests",
            // See LeonardApp/README.md: on this CLT-only toolchain, the
            // swift-testing macro plugin is sometimes not resolved for one
            // or more frontend jobs of a multi-file test target. Disabling
            // batch mode plus serial `-j 1` (see build.sh/README) has been
            // the reliable combination found so far.
            swiftSettings: [.unsafeFlags(["-disable-batch-mode", "-no-emit-module-separately"])]
        ),
    ],
    swiftLanguageModes: [.v6]
)
