// swift-tools-version: 6.0
import PackageDescription

// `LeonardCore` is platform-agnostic — contract, IPC, state, settings,
// licensing, the mail and memory policies — and builds and tests on Linux
// as well as macOS. The app itself is AppKit and exists only on macOS.

var products: [Product] = [
    .library(name: "LeonardCore", targets: ["LeonardCore"]),
]

var targets: [Target] = [
    .target(
        name: "LeonardCore",
        path: "Sources/LeonardCore",
        linkerSettings: [.linkedLibrary("sqlite3")]
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
]

#if os(macOS)
products.append(.executable(name: "LeonardApp", targets: ["LeonardApp"]))
targets.append(
    .executableTarget(
        name: "LeonardApp",
        dependencies: ["LeonardCore"],
        path: "Sources/LeonardApp",
        linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]
    )
)
#endif

let package = Package(
    name: "LeonardApp",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)
