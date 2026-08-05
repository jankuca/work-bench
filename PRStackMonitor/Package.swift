// swift-tools-version: 5.9

import PackageDescription

// LinearKit joins this package at M5. Every target here is Foundation-only so it builds
// and tests off-device (see docs/IMPLEMENTATION_PLAN.md §1); the one macOS-specific file,
// GitHubKit's Keychain store, is fenced behind `canImport(Security)`.
let package = Package(
    name: "PRStackMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRStackCore", targets: ["PRStackCore"]),
        .library(name: "GitHubKit", targets: ["GitHubKit"]),
        // Debug dump: derive a snapshot and print the panel, from a fixture file or from
        // GitHub itself. Foundation only, so CI compiles it alongside everything else.
        .executable(name: "prstack-dump", targets: ["PRStackDump"])
    ],
    targets: [
        .target(name: "PRStackCore"),
        .target(name: "GitHubKit", dependencies: ["PRStackCore"]),
        .executableTarget(name: "PRStackDump", dependencies: ["PRStackCore", "GitHubKit"]),
        .testTarget(
            name: "PRStackCoreTests",
            dependencies: ["PRStackCore"],
            // Excluded, not declared as resources: the tests reach these through
            // #filePath in the source tree rather than Bundle.module, because
            // PRSTACK_RECORD_GOLDENS=1 has to rewrite goldens in place. Copying them
            // into a bundle nothing reads would be dead weight; leaving them undeclared
            // makes SwiftPM warn about 48 unhandled files on every build.
            exclude: ["Fixtures", "Goldens"]
        ),
        .testTarget(
            name: "GitHubKitTests",
            dependencies: ["GitHubKit", "PRStackCore"],
            // Read from the source tree via #filePath, same as above.
            exclude: ["Fixtures"]
        )
    ]
)
