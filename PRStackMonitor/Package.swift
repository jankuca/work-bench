// swift-tools-version: 5.9

import PackageDescription

// Every target here is Foundation-only so it builds and tests off-device (see
// docs/IMPLEMENTATION_PLAN.md §1); the one macOS-specific file, NetKit's Keychain store,
// is fenced behind `canImport(Security)`.
//
// `NetKit` is not one of the plan's six modules. It is the seam underneath two of them:
// the HTTP transport, the GraphQL envelope and the credential providers are the same code
// whether the endpoint is GitHub's or Linear's, and the alternatives were duplicating a
// cancellation-aware `URLSession` wrapper in both kits or having `LinearKit` import
// `GitHubKit` for it. It holds no policy — every rule about rate limits, error meaning or
// retry lives in the kit that owns the API.
let package = Package(
    name: "PRStackMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRStackCore", targets: ["PRStackCore"]),
        .library(name: "NetKit", targets: ["NetKit"]),
        .library(name: "GitHubKit", targets: ["GitHubKit"]),
        .library(name: "LinearKit", targets: ["LinearKit"]),
        // Debug dump: derive a snapshot and print the panel, from a fixture file or from
        // GitHub and Linear themselves. Foundation only, so CI compiles it alongside
        // everything else.
        .executable(name: "prstack-dump", targets: ["PRStackDump"])
    ],
    targets: [
        .target(name: "PRStackCore"),
        .target(name: "NetKit"),
        .target(name: "GitHubKit", dependencies: ["NetKit", "PRStackCore"]),
        .target(name: "LinearKit", dependencies: ["NetKit", "PRStackCore"]),
        .executableTarget(
            name: "PRStackDump",
            dependencies: ["PRStackCore", "GitHubKit", "LinearKit"]
        ),
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
        .testTarget(name: "NetKitTests", dependencies: ["NetKit"]),
        .testTarget(
            name: "GitHubKitTests",
            dependencies: ["GitHubKit", "NetKit", "PRStackCore"],
            // Read from the source tree via #filePath, same as above.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "LinearKitTests",
            dependencies: ["LinearKit", "NetKit", "PRStackCore"]
        )
    ]
)
