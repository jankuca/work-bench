// swift-tools-version: 5.9

import PackageDescription

// GitHubKit and LinearKit join this package at M2 and M5. PRStackCore stays
// Foundation-only so it builds and tests off-device (see docs/IMPLEMENTATION_PLAN.md §1).
let package = Package(
    name: "PRStackMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRStackCore", targets: ["PRStackCore"])
    ],
    targets: [
        .target(name: "PRStackCore"),
        .testTarget(name: "PRStackCoreTests", dependencies: ["PRStackCore"])
    ]
)
