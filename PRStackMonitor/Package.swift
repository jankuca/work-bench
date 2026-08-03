// swift-tools-version: 5.9

import PackageDescription

// GitHubKit and LinearKit join this package at M2 and M5. PRStackCore stays
// Foundation-only so it builds and tests off-device (see docs/IMPLEMENTATION_PLAN.md §1).
let package = Package(
    name: "PRStackMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRStackCore", targets: ["PRStackCore"]),
        // Debug dump: derive a snapshot and print the panel. Foundation only, so CI
        // compiles it alongside everything else.
        .executable(name: "prstack-dump", targets: ["PRStackDump"])
    ],
    targets: [
        .target(name: "PRStackCore"),
        .executableTarget(name: "PRStackDump", dependencies: ["PRStackCore"]),
        .testTarget(
            name: "PRStackCoreTests",
            dependencies: ["PRStackCore"],
            // Excluded, not declared as resources: the tests reach these through
            // #filePath in the source tree rather than Bundle.module, because
            // PRSTACK_RECORD_GOLDENS=1 has to rewrite goldens in place. Copying them
            // into a bundle nothing reads would be dead weight; leaving them undeclared
            // makes SwiftPM warn about 48 unhandled files on every build.
            exclude: ["Fixtures", "Goldens"]
        )
    ]
)
