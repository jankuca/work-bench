# PRStackMonitor — Swift package

The portable half of the app. See [`docs/IMPLEMENTATION_PLAN.md`](../docs/IMPLEMENTATION_PLAN.md)
for the whole design; this README covers only how to work in this package.

| Target | Milestone | Notes |
| --- | --- | --- |
| `PRStackCore` | M1, M3, M4, M6, M7, M8 | Domain model and all derivation logic, plus the presentation layer the panel view reads, the event diff, the menu bar icon's state machine, the `state.json` store, the row actions behind the pointer and the keys, and the poll interval table with its per-source backoff. Foundation only, no I/O beyond that one store, no clock reads |
| `NetKit` | M5 | The seam under both service kits: HTTP transport, GraphQL envelope, credential providers. One macOS-only file, fenced. No policy |
| `GitHubKit` | M2, M6 | GraphQL + REST clients, DTOs, rate limiting, and the tag-containment release tracker |
| `LinearKit` | M5 | Identifier scan, batched `issue(id:)` resolution, the project cache |
| `prstack-dump` | M1–M6 | Debug tool: derive a fixture, or a live GitHub + Linear poll, and print the panel |

The AppKit shell (`App/`) is a separate Swift package and is not part of this one.

### Why `NetKit` exists

It is not one of the plan's six modules. `GitHubKit` and `LinearKit` are drawn as siblings
(§1), and both need the same three things: a cancellation-aware `URLSession` wrapper behind
a stubable protocol, the `{ data, errors }` envelope, and somewhere for a pasted credential
to come from. The alternatives were duplicating that transport in both — it is subtle
enough that two copies would diverge — or having `LinearKit` import `GitHubKit`, which
inverts the layering for a `URLRequest`.

`NetKit` holds **no policy**. Every rule about what a status code means, what a rate limit
costs, or when to retry lives in the kit that owns the API. That is what keeps it from
quietly becoming a third service.

### Why the scheduler is split

The plan draws `SyncEngine` as a macOS-only module (§1), and the half that watches sleep
notifications and reads IOKit's power sources is exactly that — it lives in `App/`. What
came here instead is `PRStackCore/Sync/`: the interval table, the backoff arithmetic, and
the staleness threshold the footer reads. They are decisions, not observations, and they
have the same shape as everything else in this package — pure, clock-injected, and wrong in
ways a reviewer will not see. The ordering of §4's table is the point of the whole feature
(asleep and low battery outrank an open panel), and it is only testable at all because the
conditions arrive as a value.

## Running the tests

```sh
cd PRStackMonitor
swift test
```

No macOS required — nothing here has an AppKit dependency, which is what lets CI run it in
a Linux container. `NetKit/KeychainTokenStore.swift` is the one file that needs Apple's
`Security` framework, and it is fenced behind `#if canImport(Security)` rather than split
into its own module.

No test touches the network: `HTTPTransport` is the seam, and the suite implements it. The
plan calls for a `URLProtocol` stub, which works on Apple platforms but is not dependable
in swift-corelibs-foundation — a protocol the tests conform to gives the same guarantee
without betting the suite on that difference.

## Fixtures and goldens

`Tests/PRStackCoreTests/Fixtures/*.json` are the inputs to
`Derivation.derive(snapshot:local:now:)`. Each one has **two** goldens, and every fixture
needs both — the golden tests iterate the whole directory and fail on a missing one:

| Directory | Renders | Catches |
| --- | --- | --- |
| `Goldens/*.txt` | the derived `PanelModel` | ordering, sectioning, status, unread |
| `Goldens/Presentation/*.txt` | the `PanelPresentation` over it | wording, meta line composition, tone, release track |

The second set exists because the panel is built on a Mac and the rules that decide what
it says are not. Every string the row view draws is resolved in `PRStackCore`, so it can
be pinned in the same Linux container as the rest.

A fixture is one snapshot and one clock, so the M4 event cases are built in code instead,
in `EventDiffTests` — each one needs a *pair* of models, and the connection cases a pair of
`PanelStatus` values. Moving a fixture's clock past a snooze deadline is still a fixture's
job; producing the second half of a pair is not.

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

`prstack-dump` prints either rendering for a fixture, byte-identical to that fixture's
golden:

```sh
swift run prstack-dump Tests/PRStackCoreTests/Fixtures/panel-2a.json
swift run prstack-dump --presentation Tests/PRStackCoreTests/Fixtures/panel-2a.json
```

From the repository root those are `make dump` and `make panel`.

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
swift run prstack-dump --github --presentation                # what the row view reads
```

From the repository root, `make fetch REPOS='acme/billing' PAGE_SIZE=5` does the same.

The token is a **classic personal access token** with the `repo` scope — or `public_repo`
if every repository in scope is public. It is looked for in `$PRSTACK_GITHUB_TOKEN`, then
`$GITHUB_TOKEN`, then the login keychain on macOS.

A fine-grained token does not work for the full query. `statusCheckRollup` reads check
runs, and GitHub does not offer a Checks permission on fine-grained tokens at all — per
GitHub Support the capability existed, was found to have edge cases, and was withdrawn, so
only GitHub Apps can read that API. A fine-grained token answers the search perfectly well
and then returns `FORBIDDEN: Resource not accessible by personal access token` for every
pull request's rollup, which is reported as a warning per node and leaves every row with no
CI status.

This is a real widening and worth saying plainly: `repo` is read **and write** across all
private repositories, where the fine-grained token it replaces was read-only and
per-repository. Classic scopes have no read-only equivalent that includes checks. The app
only ever issues reads, but the token it now holds could do more. Preferring a GitHub App
installation token would close that gap and is the honest long-term fix.

Diagnostics — how many pages, how many GraphQL points, why pagination stopped, and every
warning — go to stderr, so `prstack-dump --github > panel.txt` still captures only the
panel. Stopping short is normal and always reported: `pageCap`, `pointBudget` and
`rateLimitFloor` each come back with the cursor to resume from.

`--emit-snapshot` writes the fetched snapshot in the fixture shape above, so a live poll
can be replayed offline. **Anonymise it before committing it** — a raw one carries real
repository names, branch names and pull request titles.

## Talking to Linear

Linear runs after GitHub in the same poll — sequential, not parallel, because on a cold
start there are no identifiers to resolve until GitHub has answered:

```sh
export PRSTACK_LINEAR_KEY=lin_api_…             # or store it in the login keychain

swift run prstack-dump --github                        # rows group under real projects
swift run prstack-dump --github --no-linear            # everything falls to Other
swift run prstack-dump --github --linear-cache /tmp/linear.json   # run twice to see it cache
swift run prstack-dump --github --presentation --linear-token bad # `Linear stale` in the footer
```

The key is a **personal API key** from Linear → Settings → API, used read-only. It goes in
`Authorization` bare — the `Bearer` prefix is for OAuth tokens, and sending it with a
personal key is answered with an authentication error.

What the diagnostics on stderr report is the shape of the work: how many issues were
attached, how many came from cache, how many were fetched, and every identifier Linear did
not recognise. That last line is expected to be non-empty — see below.

### Identifiers that are not identifiers

The scan cannot tell `UTF-8`, `SHA-256` or `RELEASE-2026` from a real team key; they have
the same shape, and only the workspace's team list settles it. So they are scanned, asked
about once, and answered "no such issue" — which is **cached**, negatively, so the same
junk identifier is never re-queried. An identifier with nothing behind it is dropped from
the row entirely: it never reaches the meta line, and it never affects which project the
row is grouped under.

The alternative was a hard-coded deny list that goes stale, or a length cap on team keys
that Linear does not actually publish.

### The project cache

`LinearProjectCache` maps identifier → issue, is refreshed once a day, and is kept
**indefinitely**. Those are two different things and the distinction is load-bearing: the
refresh interval decides what gets re-asked, never what gets used. A Linear outage leaves
every cached heading in place and only marks the source stale in the footer — it must never
make project sections appear to empty out.

It lives in its own file, rather than inside `state.json` — the app defaults to
`~/Library/Application Support/PRStackMonitor/linear-cache.json`, and a caller that owns its
own path says so (`prstack-dump --linear-cache`). The plan
originally drew it inside `state.json`; the two turned out to have different writers, since
`LocalState` is one value owned by the main actor and written whole while the cache is
written from the resolver's own task on a background poll. Folding it in would either make
the resolver a second writer of the state file — the hazard the single-writer rule exists to
prevent — or route every cache hit through the main actor to be merged, for a field
derivation never reads.
