# PRStackMonitor — Swift package

The portable half of the app. See [`docs/IMPLEMENTATION_PLAN.md`](../docs/IMPLEMENTATION_PLAN.md)
for the whole design; this README covers only how to work in this package.

| Target | Milestone | Notes |
| --- | --- | --- |
| `PRStackCore` | M1 | Domain model and all derivation logic. Foundation only, no I/O, no clock reads |
| `GitHubKit` | M2 | Not yet present |
| `LinearKit` | M5 | Not yet present |

The AppKit shell (`App/`) is a separate Xcode project and is not part of this package.

## Running the tests

```sh
cd PRStackMonitor
swift test
```

No macOS required — `PRStackCore` has no AppKit dependency, which is what lets CI run it
in a Linux container.

## Fixtures and goldens

`Tests/PRStackCoreTests/Fixtures/*.json` are the inputs to
`Derivation.derive(snapshot:local:now:)`; `Tests/PRStackCoreTests/Goldens/*.txt` are the
rendered panel models they must produce. Every fixture needs a golden — the golden test
iterates the whole directory and fails on a missing one.

Fixtures are **synthetic**: invented repositories, logins, titles and Linear identifiers.
If a recorded API response is ever used to get a shape right, it must be fully anonymised
before it is committed. These fixtures describe private repositories, so scrubbing only
credentials would still publish the contents of somebody's work.

Fixture files are read from the source tree rather than from a bundle resource, so goldens
can be re-recorded in place:

```sh
PRSTACK_RECORD_GOLDENS=1 swift test
git diff PRStackMonitor/Tests/PRStackCoreTests/Goldens
```

Always read that diff before committing it. A golden that changed silently is the
regression the golden was there to catch.

### Fixture format

```jsonc
{
  "now": "2026-01-10T12:00:00Z",       // the injected clock
  "snapshot": { "viewerLogin": "…", "pullRequests": [ … ] },
  "local": { "dismissed": [], "snoozedUntil": {}, "readDigests": {}, "releaseBindings": {} },
  "readAsOfSnapshot": ["acme/billing#4012"]   // "the panel was open and this is what it looked like"
}
```

Pull request fields default aggressively so fixtures stay small: `state` defaults to
`open`, `checks` to `noChecks`, `mergeable` to `unknown`, `author` to the viewer, `url` to
the canonical GitHub URL, and `createdAt` to `updatedAt`. `checks` accepts either
`"passing"` or `{"state": "failing", "failingCount": 2}`.

Prefer `readAsOfSnapshot` over writing digest strings by hand — it pins the unread *rule*
rather than the digest *format*.
