import Foundation
import PRStackCore

/// `state.json` for the dump tool.
///
/// Without `--state` everything is in memory and each run starts cold, which is what every
/// milestone before this one did. With it, the tool reads and writes the same file the app
/// does — running twice against a repository that has just cut a release is how you watch a
/// binding be made once and then survive (IMPLEMENTATION_PLAN §7).
enum StateSource {
    static func store(options: DumpOptions) -> any StateStore {
        guard let path = options.statePath else { return InMemoryStateStore() }
        return FileStateStore(url: URL(fileURLWithPath: path))
    }

    /// Loads, and says on stderr when the file had to be moved aside. Quietly starting from
    /// empty is exactly the failure the quarantine exists to make visible.
    static func load(_ store: any StateStore) -> LocalState {
        let loaded = store.load()
        if let failure = loaded.failure {
            let moved = loaded.quarantinedTo.map { "; moved to \($0.path)" } ?? ""
            Diagnostics.write("warning: starting from empty local state — \(failure)\(moved)")
        }
        return loaded.state
    }

    static func save(_ state: LocalState, to store: any StateStore) throws {
        do {
            try store.save(state)
        } catch {
            throw DumpFailure(String(describing: error))
        }
    }
}
