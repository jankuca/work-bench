# PRStackMonitor — Swift package

The portable half of the app. See [`docs/IMPLEMENTATION_PLAN.md`](../docs/IMPLEMENTATION_PLAN.md)
for the whole design; this README covers only how to work in this package.

| Target | Milestone | Notes |
| --- | --- | --- |
| `PRStackCore` | M1 | Domain model and all derivation logic. Foundation only, no I/O, no clock reads |
| `GitHubKit` | M2 | GraphQL + REST clients, DTOs, rate limiting. One macOS-only file, fenced |
| `LinearKit` | M5 | Not yet present |
| `prstack-dump` | M1–M2 | Debug tool: derive a fixture, or a live GitHub poll, and print the panel |

The AppKit shell (`App/`) is a separate Swift package and is not part of this one.

## Running the tests

```sh
cd PRStackMonitor
swift test
```

No macOS required — nothing here has an AppKit dependency, which is what lets CI run it in
a Linux container. `GitHubKit/KeychainTokenStore.swift` is the one file that needs Apple's
`Security` framework, and it is fenced behind `#if canImport(Security)` rather than split
into its own module.

No test touches the network: `HTTPTransport` is the seam, and the suite implements it. The
plan calls for a `URLProtocol` stub, which works on Apple platforms but is not dependable
in swift-corelibs-foundation — a protocol the tests conform to gives the same guarantee
without betting the suite on that difference.

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
git diff -- Tests/PRStackCoreTests/Goldens
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

`Tests/GitHubKitTests/Fixtures/` holds response shapes rather than derivation inputs, and
the same anonymisation rule applies to them.

## Talking to GitHub

`prstack-dump --github` runs one real poll and prints the panel it derives, which is what
M2 is demoable against:

```sh
export PRSTACK_GITHUB_TOKEN=github_pat_…        # or store it in the login keychain

swift run prstack-dump --github                 # All scope
swift run prstack-dump --github --repo acme/billing --repo acme/source   # Selected scope
swift run prstack-dump --github --page-size 5   # force pagination past the first page
swift run prstack-dump --github --emit-snapshot /tmp/live.json
```

From the repository root, `make fetch REPOS='acme/billing' PAGE_SIZE=5` does the same.

The token is a **fine-grained personal access token**, read-only, with `Contents: read`,
`Pull requests: read` and `Metadata: read`. It is looked for in `$PRSTACK_GITHUB_TOKEN`,
then `$GITHUB_TOKEN`, then the login keychain on macOS.

Diagnostics — how many pages, how many GraphQL points, why pagination stopped, and every
warning — go to stderr, so `prstack-dump --github > panel.txt` still captures only the
panel. Stopping short is normal and always reported: `pageCap`, `pointBudget` and
`rateLimitFloor` each come back with the cursor to resume from.

`--emit-snapshot` writes the fetched snapshot in the fixture shape above, so a live poll
can be replayed offline. **Anonymise it before committing it** — a raw one carries real
repository names, branch names and pull request titles.
