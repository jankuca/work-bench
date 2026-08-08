import Foundation
import PRStackCore

// A debug dump for the derivation: read a snapshot, derive it, print the panel.
//
// M2's done-criteria is "real pull requests appear in a debug dump under both All and
// Selected scope, including past the first page of 50", so `--github` fetches live and
// everything else here is shared with the fixture path. Its output for a fixture is
// byte-identical to that fixture's golden, which is what makes the two comparable.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

do {
    let options = try DumpOptions.parse(Array(CommandLine.arguments.dropFirst()))

    let input: DumpInput
    // A fixture arrives with its issues already resolved, so it has no Linear source to be
    // stale about and renders as connected.
    var linearHealth = SourceHealth.connected

    switch options.source {
    case .file(let path):
        input = try DumpInput.read(path: path)
    case .github:
        // Sequential, not parallel: on a cold start there are no identifiers to resolve
        // until GitHub has answered (IMPLEMENTATION_PLAN §1).
        let now = options.now ?? Date()
        let fetch = try await GitHubSource.fetch(options: options)
        let resolved = await LinearSource.resolve(fetch.pullRequests, options: options, now: now)
        linearHealth = resolved.health ?? .connected
        input = DumpInput(
            now: now,
            snapshot: RawSnapshot(viewerLogin: fetch.viewerLogin, pullRequests: resolved.pullRequests)
        )
    }

    if let path = options.emitSnapshotPath {
        try input.write(to: path)
    }

    let rendered = options.rendersPresentation
        ? PanelPresentationReport.render(input.present(now: options.now, linear: linearHealth))
        : PanelModelReport.render(input.derive(now: options.now))
    print(rendered, terminator: "")
} catch let failure as DumpFailure {
    fail(failure.message)
} catch {
    fail(String(describing: error))
}
