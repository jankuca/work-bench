// swift-tools-version: 5.9

import PackageDescription

// The AppKit shell lives in its own package, separate from `../PRStackMonitor`.
//
// That split is the CI boundary from docs/IMPLEMENTATION_PLAN.md §1: the portable
// modules build and test in a Linux container, this one needs a Mac. Keeping them in
// two packages means CI never has to know this target exists.
//
// There is no .xcodeproj. `make run` assembles and signs the .app bundle from this
// executable, which keeps the build reproducible from the command line and avoids a
// generated project file nobody reads. Xcode can still open this package directly
// (`xed App`) for editing and debugging.
let package = Package(
    name: "PRStackMonitorApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        // By path, not by URL: the two packages are one repository and always move
        // together, so a version requirement would be a fiction to maintain.
        .package(path: "../PRStackMonitor")
    ],
    targets: [
        .executableTarget(
            name: "PRStackMonitorApp",
            dependencies: [
                .product(name: "PRStackCore", package: "PRStackMonitor"),
                .product(name: "NetKit", package: "PRStackMonitor"),
                .product(name: "GitHubKit", package: "PRStackMonitor"),
                .product(name: "LinearKit", package: "PRStackMonitor")
            ]
        )
    ]
)
