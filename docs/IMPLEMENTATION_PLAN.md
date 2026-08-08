# PR Stack Monitor — Implementation Plan

Swift / macOS menu bar app. Source of truth for scope: [`design/PRD.dc.html`](../design/PRD.dc.html).
Source of truth for visuals: iteration **2a** at the top of [`design/Tray App.dc.html`](../design/Tray%20App.dc.html)
("Single scroll, stacks drawn as a spine"). The numbered iterations `1a`–`1f` below it are superseded,
except as a reference for states 2a doesn't draw: `1c` (release grouping), `1e` (first run + expired token),
`1f` (tray icon state set). `1d`'s collapsed stacks are **not** being built — see §5.

Open questions from PRD §12 have been answered by the product owner; §8 records the decisions and the rest of
the document already reflects them. Two of those answers narrow the PRD: no collapsing (§5) and tags-only
release tracking (§3).

---

## 0. Constraints that shape the plan

### No Apple Developer account (initially)

Everything below is buildable and runnable on the developer's own Mac with a free Xcode install. What we
give up, and how we work around it:

| Capability | Without a paid account | Plan |
| --- | --- | --- |
| Running a locally built `.app` | Works. Gatekeeper only gates *downloaded* apps (quarantine bit) | Build and launch locally; no workaround needed |
| Code signing | Ad-hoc (`codesign -s -`) or a **self-signed local certificate** created in Keychain Access | Create a local cert `PRStackMonitor Local` once; sign every build with it |
| Keychain item ACLs | Ad-hoc signatures change hash every build → macOS re-prompts for keychain access on each rebuild | Use the stable self-signed identity so the designated requirement stays constant across rebuilds |
| App Sandbox | Works unsigned/self-signed, but any entitlement needing a provisioning profile (iCloud, App Groups, Push) does not | Ship v1 **unsandboxed**. No entitlement in the app needs a profile, so sandboxing can be switched on later without redesign |
| `UNUserNotificationCenter` | Unreliable for non-notarized bundles; can fail to register | Don't ship notifications in v1, but build the event bus they'd plug into (§1). Menu bar icon is the only alert channel for now |
| Launch at login (`SMAppService`) | Generally works for a self-signed app in `/Applications`, but is the flakiest of these | Behind a setting, off by default, with a documented manual fallback (System Settings → Login Items) |
| Distribution / notarization / Sparkle | Not possible | Out of scope. Distribution is "build and copy to `/Applications`" |

**Rule:** nothing in v1 may depend on a capability that requires a team ID. Getting an account later should
be a signing-settings change plus enabling notifications, not a refactor.

### Environment note

The repo currently has no Swift toolchain available in CI (Linux container, no `swift`). The plan
deliberately keeps all non-UI logic in platform-neutral Swift modules so they *can* be compiled and tested
on Linux once a toolchain is installed — see §6.

---

## 1. Architecture

Six modules. Three of them — `PRStackCore`, `GitHubKit`, `LinearKit`, drawn at the bottom of the diagram —
are pure Swift (Foundation only, no AppKit) and build and test off-device. `PanelUI` and `SyncEngine` are
macOS-only and are the CI boundary: they compile on a Mac, not in a Linux container.

```text
PRStackMonitor.app  (AppKit shell: NSStatusItem, NSPopover, SwiftUI views)
        │
        ├── PanelUI            SwiftUI views + design tokens          (macOS only)
        ├── SyncEngine         scheduling, coalescing, staleness      (macOS only: power/sleep)
        │
        ├── GitHubKit          GraphQL + REST clients, DTOs           (portable)
        ├── LinearKit          GraphQL client, issue→project          (portable)
        └── PRStackCore        domain model + all derivation logic    (portable, no I/O)
```

`PRStackCore` owns every decision the UI renders: what a row's status is, what the icon shows, what counts
as unread, how stacks are ordered. It takes snapshots in and produces a `PanelModel` out. It performs no
networking, no persistence, no clock reads (time is injected). That is what makes the state machine
testable without a Mac in the loop.

### Data flow

Linear resolution depends on identifiers extracted from the GitHub payload, so the two fetches are
**sequential, not parallel** — on a cold start there are no identifiers to resolve until GitHub has answered.
(Subsequent polls can overlap them speculatively using the cached identifier set, but correctness never
depends on that.)

```text
poll tick
   │
   ├─► GitHubKit.fetch(repoScope) ──► [PullRequestDTO]
   │                                     │
   │                                     ├─► extract issue identifiers
   │                                     │        │
   │                                     │        └─► LinearKit.resolve(ids) ──► [IssueRef]
   │                                     │                                            │
   │                                     └────────────────┬───────────────────────────┘
   │                                                      ▼
   │                                                 RawSnapshot ─┐
   ├─► Persistence.load() ───────────────► LocalState ────────────┤
   └─► SyncEngine holds ─────────────────► previous: PanelModel? ─┤
                                                                  ▼
                                                    PRStackCore.derive(...)
                                                                  │
                                        ┌─────────────────────────┼─────────────────────┐
                                        ▼                         ▼                     ▼
                                   PanelModel               IconState            [DomainEvent]
                                        │                         │                     │
                                     PanelUI          StatusItemController      EventBus ─► sinks
```

```swift
func derive(snapshot: RawSnapshot,
            local: LocalState,
            previous: PanelModel?,   // nil on cold start
            now: Date) -> (model: PanelModel, events: [DomainEvent])
```

`local` = dismissed IDs, snooze deadlines, last-read digests, release bindings. `previous` is the model from
the last derivation, held by `SyncEngine` and **not persisted**. Derivation is a pure function of all four
inputs; the same inputs always yield the same panel and the same event list.

`previous: nil` is the cold-start baseline: the model is built normally and the event list is **empty**, so
a relaunch never replays history as fresh activity. Unread dots on relaunch come from the persisted read
digests, which is a separate mechanism — that distinction gets an explicit test (`relaunch emits no events
but preserves unread`).

### Snooze semantics

A PR with a snooze deadline in the future (`local.snoozedUntil[id] > now`) is **suppressed**:

- `RowStatus` still resolves normally, but `isAttention` is forced false — no warm tint, no bolder title.
- The row does not count toward the icon's red badge, and cannot raise the icon out of idle.
- **Attention events** are withheld — `changesRequested`, `checksFailed` and the like. Lifecycle events are
  not: `reachedProduction` still fires, and `shipped`/`closed` still move the row to Done. Snooze silences
  "this needs you", not "this finished".
- The row renders dimmed with the wake time in the meta line (PRD §8).

**Effective state, not raw status, is what gets diffed.** Each row carries
`effective = (status, isSuppressed)`, and `previous` stores that pair. Diffing raw `RowStatus` alone would
lose expiry: a PR that goes `checksFailing` *during* its snooze writes `checksFailing` into `previous`, so at
wake time the status is unchanged and no transition exists to detect. With the pair, the row moves from
`(checksFailing, suppressed)` to `(checksFailing, active)` — a real transition, which emits the withheld
attention event exactly once, at wake.

The deadline is compared against the injected `now`, so expiry is deterministic: at `now >= deadline` the row
resumes full derivation with no further input and no user action. Two fixtures pin it —
`snooze-status-changed-while-asleep` (the case above) and `snooze-expiry-no-underlying-change` (nothing
changed during the snooze, so waking emits nothing).

### Event bus (the notification extension point)

Derivation also returns the **transitions** it observed, not just the new state:
`reachedProduction(PRID)`, `changesRequested(PRID)`, `checksFailed(PRID)`, `becameMergeable(PRID)`,
`newComments(PRID, count)`, `connectionLost(Source)`. These are diffed against `previous`, so they're a pure
by-product of derivation and equally testable.

```swift
protocol EventSink { func handle(_ events: [DomainEvent], context: PanelModel) }
```

v1 registers exactly one sink — the unread/icon updater. Adding "notify me when my PR reaches production"
later means writing a `UserNotificationSink` (~40 lines: request authorization, map event → `UNNotification`,
respect a per-event-type toggle in Settings) and registering it. No change to core, sync, or UI. Keep the
sink list and the per-event Settings toggles in place from M4 even though only one sink exists, so the
extension is a drop-in rather than a retrofit.

### Framework choices

- **`NSStatusItem` + `NSPopover`, not `MenuBarExtra`.** We need per-frame control of the icon (badge count
  drawn into the image, amber pulse animation, dashed disconnected glyph) and predictable popover
  dismissal. `MenuBarExtra(.window)` makes both awkward. The popover *content* is SwiftUI via
  `NSHostingView`.
- **SwiftUI for the panel.** The list is ~10–25 rows; `LazyVStack` in a `ScrollView` is sufficient and gives
  us the exact geometry control the design needs (the spine cannot be drawn with `List` insets).
- **Deployment target macOS 14.** Buys `Observable`, `ScrollView` refinements, `SMAppService`. No reason to
  go older for a personal tool.
- **No third-party dependencies.** Hand-rolled GraphQL requests (they're just POSTed strings), `Codable`
  DTOs, `URLSession`. Avoids the supply-chain and signing complications entirely.

---

## 2. Domain model (`PRStackCore`)

```swift
struct PullRequest {
  let id: PRID                 // repo + number
  var title: String
  var body: String?            // nullable; scanned for issue identifiers
  var number: Int
  var url: URL
  var headRef: String, baseRef: String
  var isDraft: Bool
  var state: GitHubState       // open / merged / closed
  var reviewDecision: ReviewDecision?      // approved / changesRequested / reviewRequired
  var reviews: [ReviewerState] // login, avatar seed, state
  var checks: CheckRollup      // passing / failing(n) / running / none
  var mergeable: Mergeable     // mergeable / conflicting / unknown
  var mergeCommit: String?
  var updatedAt: Date, createdAt: Date
  var commentCount: Int, lastCommentAt: Date?
  var linearIssues: [IssueRef]  // ordered, may be empty; resolved by LinearKit
}

extension PullRequest {
  /// First linked issue that has a project; falls back to the first linked
  /// issue; nil when none are linked. Drives section placement and the meta line.
  var primaryIssue: IssueRef? { ... }
}

struct Stack { var members: [PRID] }        // ordered top-most first, base last
struct Release { var tag: String; var prs: [PRID]; var taggedAt: Date }

/// Semantic release stage. v1's tag tracker only ever produces the first three
/// cases; `deploying` and `deployFailed` exist so a DeploymentAPITracker can
/// populate them without changing this type or the views that switch over it.
enum ReleaseStage {
  case unmerged            // segment 2 and 3 empty
  case mergedAwaitingTag   // segment 2 filled
  case released(tag: String)
  case deploying(tag: String)      // reserved — not produced in v1
  case deployFailed(tag: String)   // reserved — not produced in v1
}
```

### Row status — single value, strict precedence

Each row resolves to exactly one `RowStatus`. First match wins:

Terminal states are checked **first**, because they're facts about the PR rather than signals about it — a
closed PR carries whatever stale review metadata it had at close, and must not fall through to a live status:

1. `closed` — state == closed and not merged → grey, Done section
2. `shipped` — merged **and** merge commit contained in a matching tag → green, moves to Done
3. `merged` — merged, no matching tag yet → purple, meta reads `merged · awaiting release`

Then, for open PRs only, first match wins:

4. `conflicted` — mergeable == conflicting → red
5. `changesRequested` — review decision → red
6. `checksFailing` — check rollup failing → red
7. `blocked(on: PRID)` — parent PR still open → neutral grey, meta reads `waiting on #NNNN`
8. `approved` / `readyToMerge` — green (`readyToMerge` when approved **and** checks green **and** mergeable)
9. `inReview` — default fallback

Fixtures pin the ordering hazard directly: a closed PR with no review metadata, and a closed PR carrying a
stale `changesRequested` decision, must both resolve to `closed` and land in Done.

Invariant from the PRD (§5.2): *a row that needs attention always has a matching icon; a green icon never
appears in a tinted row.* Encode this as a unit test over all `RowStatus` × tint combinations, not as a
convention.

**Attention** = statuses 4–6, and only when the row is not snoozed. That set drives the warm tint, the bolder
title weight, and the red badge count. Note 7 (`blocked`) is deliberately **not** attention — it's the layer
below's problem.

Under tags-only release tracking (§3) there is no deploy-failure signal, so no deploy state can reach
attention. See the note there — this is the one place the model is narrower than the PRD.

### Stack derivation

Build a `(repo, headRef) → PR` index over the user's own open PRs; a PR's parent is the PR whose
`(repo, headRef)` equals this PR's `(repo, baseRef)`. **The repository must be part of the key.** Branch names
like `main`, `develop` or `release` recur across repos, so a `headRef`-only index would join unrelated PRs
into a phantom stack and mark one `blocked` on a PR in a different repository — the exact failure
`stack-parent-foreign-repo` exists to catch. Authorship is filtered the same way: only the user's own PRs
enter the index, so a parent branch owned by someone else never matches.

Chains of length ≥ 2 become a `Stack`, rendered top-most first (walk to the leaf, emit downward). Cases to
handle explicitly, each with a fixture test:

Each case below is a **named fixture with golden assertions** in `PRStackCoreTests`, not just a documented
intention — fixture names in parentheses:

- **Merged out of order** (`stack-merged-out-of-order`) — merged parent drops out; children re-target trunk;
  spine reflows silently.
- **Fork, two PRs share a base** (`stack-fork-sibling-runs`) — the design assumes a linear chain. Decision:
  the longest chain keeps the spine; sibling branches render as their own runs directly beneath. No error
  state. Golden asserts both runs and their relative order.
- **Cycle** (`stack-cycle-guard`) — impossible in git but cheap to guard: visited-set, break, and emit the
  members as loose PRs. Golden asserts no spine is drawn.
- **Parent in another repo** (`stack-parent-foreign-repo`) and **parent authored by someone else**
  (`stack-parent-foreign-author`) — not a stack; each row renders normally with no spine and no
  `blocked` status.

### Project grouping (Linear)

A PR routinely resolves **more than one** Linear ticket — "Fixes BIL-312, BIL-313", or a branch named for one
issue whose body closes two more. Extraction therefore collects an **ordered set** of identifiers, not the
first match, scanning in this order and de-duplicating while preserving first-seen position:

1. Branch name — `([A-Z][A-Z0-9]+-\d+)`
2. PR title, in reading order
3. Body: `linear.app/…/issue/XXX-123` URLs and bare identifiers, in reading order

No identifiers at all, or no linked issue that has a project → **Other**.

#### One row, one section — the primary issue

`LinearKit.resolve(ids)` must **preserve that order on the way out.** It answers from two places — the
on-disk cache and the aliased GraphQL response — so it collects both into an `[Identifier: IssueRef]` map and
then rebuilds the array by walking the *original ordered identifier list*, never by appending cache hits and
response fields in the order they arrived. Otherwise a PR linking `BIL-312` and `SRC-97` yields
`[BIL-312, SRC-97]` on the poll where both are cached and `[SRC-97, BIL-312]` on the poll where one is
freshly fetched — and the row silently migrates from Billing to Source. Fixture:
`linear-resolve-order-cache-vs-fresh`.

The **primary issue** is the first identifier in that order whose issue has a project, falling back to the
first identifier overall. The row is grouped under the primary's project and nothing else. Because the order
derives from PR fields rather than API response order, the primary is stable across polls, which is what
keeps a row from migrating between sections (PRD §5.1).

A PR whose tickets span **two projects** still renders once, under its primary. The alternative — showing the
row in every project it touches — was rejected: `PRID` is the key for unread digests, dismissal tombstones,
snooze deadlines and stack membership, so a duplicated row would either double-count in the badge or need all
four of those keyed by (PR, project) instead. The branch name is the strongest signal of what a PR is *for*,
and it's first in the scan order, so the common case lands where the author would expect.

The extra tickets are not hidden: the meta line shows `BIL-312 +2` (§5), and the overflow opens the full list.
Fixtures `pr-multiple-issues-same-project` and `pr-multiple-issues-cross-project` pin both the grouping and
the affix.

#### Stacks that span projects

Related, and previously unspecified: a stack's members can resolve issues in different projects, but a run is
drawn as adjacent rows and cannot straddle two section headings. **The stack takes the project of its base
PR** — the bottom-most member, the one targeting trunk — and every member renders in that run regardless of
its own primary issue. The base is the stack's anchor and the member least likely to change, so this is the
stable choice; picking by majority would let a single new top-most PR relocate the whole run. A member whose
own project differs still shows its own identifier in its meta line, so the divergence is visible without
splitting the spine. Fixture: `stack-spanning-projects`.

Resolution keeps the **full identifier** as the key throughout. Linear's `issue(id:)` accepts the
human-readable identifier directly, so each uncached identifier is one aliased field in a single batched
query:

```graphql
query { a: issue(id: "BIL-312") { identifier url project { id name } }
        b: issue(id: "SRC-97")  { identifier url project { id name } } }
```

Multi-ticket PRs simply contribute more aliases; the batch is per *identifier*, not per PR, so a ticket
referenced by two PRs is fetched once and cached once.

Do **not** resolve via `issues(filter: { team: { key: { in: [...] } }, number: { in: [...] } })`. Independent
`in` lists match the cross-product: given `BIL-312` and `SRC-97`, that filter also matches `BIL-97` and
`SRC-312`, silently filing PRs under the wrong project. If a filtered query is ever needed for volume, results
must be matched back by returned `identifier` — never by position or by number alone. A two-team fixture
(`linear-cross-team-number-collision`) pins this.

Cache the identifier → project mapping on disk, refreshed on cache miss and once a day. **When Linear is
unavailable, cached mappings are still used** — rows keep their project headings, and only identifiers with no
cached entry fall into `Other`. Linear is marked stale in the footer rather than silently reshuffling the
panel; a Linear outage must never make project sections appear to empty out.

Section order: projects by most recent activity among their PRs, then `Other`, then `Done`. **Within a
section, order is stable and fully deterministic** — never API order:

1. Stack runs first, ordered by their **base PR number, descending**.
2. Then loose PRs by PR number, descending.

Stack members within a run stay top-most first, base last. A golden test with two runs in one project pins
run ordering, since API order alone would let whole runs swap places between polls. Never re-sort by urgency
(PRD §5.1).

### Unread

Per PR, store a digest of `(reviewDecision, checkRollup, mergeable, commentCount, lastCommentAt, releaseStage)`
at the moment the panel was last open. Unread = digest differs. Opening the panel rewrites all digests;
`Mark all read` does the same on demand. Dismissal (Done rows) is permanent — a tombstone set that
suppresses the PR forever, even if a later event touches it (PRD §5.3).

---

## 3. Data sources

### GitHub

Auth: **fine-grained personal access token**, pasted in Settings, scopes read-only (`Contents: read`,
`Pull requests: read`, `Metadata: read` — Contents covers tags and commit comparison). No OAuth app, no callback
URL, no Apple involvement. Device Flow can replace this later without touching the sync layer — hide it all
behind a `TokenProvider`.

**Repo scope** is a two-mode setting:

- **All** — every repo the user authors PRs in. Query qualifier is just `is:pr author:@me -is:draft`.
- **Selected** — a checklist of repos. Multiple `repo:` qualifiers in one search query are OR'd, so this is
  still a single request, not one per repo.

Settings shows the same list either way: the union of repos seen in recent results, each with a checkbox,
plus the All/Selected toggle. Switching to Selected pre-checks whatever is currently visible, so the mode
switch never blanks the panel. Trunk is whatever each repo reports as `defaultBranchRef` — not configured
per repo, just read.

One GraphQL search per poll (not per repo), **paginated to completion**:

```graphql
rateLimit { cost remaining resetAt }
search(query: "is:pr author:@me -is:draft <repo qualifiers>", type: ISSUE, first: 50, after: $cursor) {
  pageInfo { hasNextPage endCursor }
  nodes { ... on PullRequest {
    number title body url headRefName baseRefName isDraft state createdAt updatedAt mergedAt
    mergeable  reviewDecision  mergeCommit { oid }
    repository { nameWithOwner  defaultBranchRef { name } }
    comments(last: 1) { totalCount nodes { createdAt } }   # totalCount + lastCommentAt
    reviews(last: 20) { nodes { author { login avatarUrl } state submittedAt } }
    commits(last: 1) { nodes { commit { statusCheckRollup {
      state
      contexts(first: 20) {
        totalCount
        nodes {
          __typename
          ... on CheckRun     { name conclusion status detailsUrl }
          ... on StatusContext { context state targetUrl }
        }
      }
    } } } }
  } }
}
```

`contexts` returns the `StatusCheckRollupContext` union, so it needs inline fragments on both members —
`CheckRun` (Actions and most apps) and `StatusContext` (legacy commit statuses). A bare selection set does not
compile. The rollup `state` alone drives the green/red/amber segment; the per-context nodes exist so the
failing check's name can appear in the status phrase (`2 checks failed`).

Loop on `pageInfo.hasNextPage`, passing `endCursor` as `after`, until exhausted. This is not optional in
either scope: All mode would otherwise silently drop everything past the 50th PR, and Selected mode would
drop repos whose PRs happen to sort onto a later page. A safety cap of 10 pages (500 PRs) guards against a
runaway loop; hitting it surfaces a footer warning rather than truncating silently.

Field notes, since the domain model depends on them: `repository.nameWithOwner` supplies repo identity for
`PRID` and the meta-line repo name; `repository.defaultBranchRef.name` is the trunk (§ repo scope);
`mergedAt` is the merge **time** — `mergeCommit.oid` is only the commit ID and carries no timestamp;
`comments(last: 1)` yields both `totalCount` and the newest `createdAt` for `lastCommentAt`, both of which
feed the unread digest. **`body` is nullable and must be carried through the DTO** — it is the third source
in the identifier scan (§2), so omitting it silently drops body-only references like a `linear.app` URL under
"Closes:", filing the PR under `Other` or picking the wrong primary project. Both this query and the
merged-PR query select it.

### Rate limiting — points, not requests

GraphQL bills **points computed from node counts**, not one point per request. The nested
`reviews(last: 20)` and `contexts(first: 20)` selections multiply against 50 PRs per page, so request counts
alone are a poor proxy for the 5,000/hr budget. Every query therefore selects
`rateLimit { cost remaining resetAt }` and the client records the *actual* cost of each call rather than
estimating it.

The scheduler holds a **per-poll point budget** (default 100, roughly one full page of the search plus tag
queries). Exceeding it defers remaining pagination to the next poll. When `remaining` drops below 10% of the
hourly allowance, drop to the idle interval, set the REST comparison budget to zero (§ release tracking), and
mark the footer stale until `resetAt`. Backing off on the *measured* remaining points, before exhaustion,
avoids the failure mode where the app is hard-blocked mid-poll and shows a disconnected icon for the rest of
the hour.

**Merged PRs** are fetched by a second query whose lower bound is *dynamic*, not a fixed window: it starts at
the oldest **unbound** merged PR still in local state (i.e. merged but not yet matched to a tag), defaulting
to 14 days back when there are none. Unbound merged PRs are persisted indefinitely with their merge commit,
so a release cut six weeks after the merge still binds and still flips the row to shipped. A fixed 14-day
window would drop the PR out of the query, lose the merge commit, and leave it stranded at
`merged · awaiting release` forever — exactly the case PRD §10 says should resolve quietly whenever the tag
finally appears.

### Release tracking — tags only

**Shipped means "the merge commit is contained in a tag matching the pattern."** No Deployments API, no
workflow runs, no deploy outcome.

Tag patterns are stored as a **repository-keyed map**, `[String: String]` from `nameWithOwner` to glob, with
`v*` as the default for any repo without an entry. A single global pattern can't serve a user whose repos tag
as `v1.2.3` and `release-2026-01-04`; Settings edits the per-repo value inline in the repo list, showing the
default greyed out until overridden.

1. On merge, record `mergeCommit.oid` and `mergedAt`. Fallback if the oid is absent (squash rewrote history):
   match `(#NNNN)` in recent trunk commit messages.
2. Poll tags via GraphQL, **paginated**, ascending by tag commit date:

   ```graphql
   refs(refPrefix: "refs/tags/", query: <literal prefix of glob, or omitted>,
        first: 100, after: $cursor,
        orderBy: { field: TAG_COMMIT_DATE, direction: ASC }) {
     pageInfo { hasNextPage endCursor }
     nodes {
       name
       target {
         __typename
         oid
         ... on Commit { committedDate }              # lightweight tag
         ... on Tag {                                 # annotated tag
           tagger { date }
           target { ... on Commit { oid committedDate } }
         }
       }
     }
   }
   ```

   Three schema details that are easy to get wrong: `orderBy` takes a `RefOrder` where **both** `field` and
   `direction` are required; `committedDate` lives on `Commit`, **not** on `Tag`, so an annotated tag needs
   `tagger { date }` or its target commit's date; and an annotated tag's `target.oid` is the *tag object's*
   id, not the commit's — the commit oid is one level further in. Containment is tested by tag **name**, so
   this matters only for dating and ordering, but silently comparing a tag-object oid to a merge commit would
   never match.

   **`refs.query` is a substring name filter, not a glob matcher.** It can only be used as a coarse
   server-side prefilter, built from the literal prefix of the configured pattern (`v*` → `v`,
   `release-*` → `release-`) and **omitted entirely** when the pattern opens with a wildcard (`*-prod`).
   The configured glob is then applied **locally**, in full `fnmatch` semantics, to every returned ref, and
   only refs passing that local match become candidates. Without this, `*-prod` would admit every tag in the
   repository and bind a PR to a staging tag.

   Walk every page: a repo that tags often can easily push the matching tag past the first page, and a
   truncated candidate list produces a false "not shipped yet" that never self-corrects.

   **Server ordering is for pagination determinism only — do not treat it as the candidate order.**
   `TAG_COMMIT_DATE` sorts by the *target commit's* date, not by when the tag was cut, so a tag created today
   against an older commit sorts ahead of one cut last week against a newer commit. Since the binding is
   permanent, taking the server's first hit can pin a PR to a later release forever. After pagination,
   resolve each candidate's own timestamp — `tagger.date` for annotated tags, the target commit's
   `committedDate` for lightweight ones, which is the only date they carry — then filter to
   `taggedAt > mergedAt` and sort locally by `(taggedAt, name)`. The name breaks ties deterministically so
   two tags on the same commit always resolve the same way. Only then run the containment tests, oldest
   first. Fixture: `release-annotated-tag-on-older-commit`.
3. Test containment **oldest candidate first** with `GET /repos/{o}/{r}/compare/{tag}...{sha}`: `status` of
   `identical` or `behind` means the tag contains the commit. First hit wins — that's the release the PR
   shipped in, and testing oldest-first is what makes it the *earliest* such release rather than an arbitrary
   one. Bind PR → tag and cache the binding permanently; never re-test a bound PR.
4. A tag carries several of the user's PRs, so they flip to shipped together — the `1c` release grouping,
   for free.

#### Bounding the comparisons

A negative result must be **as durable as a positive one**. Each unbound merged PR persists
`comparedTags: Set<TagName>`; a tag already in that set is never compared again for that PR. Without it, an
unbound PR re-tests every candidate tag on every poll — N unbound PRs × K candidate tags *per poll*, forever,
which for 10 stranded merges in a repo with 25 matching tags is 250 requests every 60 seconds. The set is
bounded by tags cut since that PR merged and is discarded the moment the PR binds; a PR unbound for months in
a busy repo costs a few hundred short strings, which is acceptable and self-limiting.

On top of that, a hard **per-poll comparison budget** (default 20, oldest candidates first). Exceeding it
defers the remainder to the next poll rather than blocking the sync — a PR shipping is not urgent enough to
spend a rate limit on, and the persisted set means the work already done is never repeated. Steady state
after the first poll following a release cut is near zero comparisons, since only genuinely new tags are
untested.

A fixture with 25+ matching tags and the containing tag on the second page (`release-tag-on-later-page`) pins
the pagination requirement; `release-compare-not-repeated-across-polls` pins the durability of negatives.

**What this model gives up**, relative to PRD §4/§7 — worth stating plainly, since it removes states the
design draws:

- **No "deploy in flight."** A tag either contains the commit or doesn't. The amber pulsing icon state and
  the pulsing third segment have no input, so the icon drops to four states — see the priority table in §5,
  which is authoritative for their ordering.
- **No "deploy failed / held."** Nothing can raise a merged PR to action-needed. PRD §7's "deploy failed"
  outcome and §10's "rolled back after being reported live" are both undetectable and out of scope.
- **The three-segment track re-reads** as *CI → merged to trunk → in a release tag*. Same three segments,
  same visual language; the third fills on tag containment rather than on a production deploy succeeding.
  Segments no longer pulse.

This is a deliberate simplification and it removes roughly a milestone of work. Everything sits behind a
`ReleaseTracker` protocol with `TagContainmentTracker` as the v1 implementation. `ReleaseStage` (§2) already
carries `deploying` and `deployFailed` cases that v1 never produces, and both `PRStackCore` and the row view
switch over the full enum from the start, so a `DeploymentAPITracker` can populate them without changing the
model or the view. Two things it *would* still touch: `RowStatus` gains a `deployFailed` case in the attention
set, and the icon regains its amber in-flight state (the drawing code keeps that case, §5). That's the honest
scope of the seam — the data path and the segment rendering are ready; the attention rules are not.

Budget: GraphQL 5,000 points/hr, REST 5,000 req/hr. Per poll, now that the searches paginate:

| Call | Requests per poll |
| --- | --- |
| PR search | 1 per 50 open PRs (1 typical, capped at 10 pages or the per-poll point budget) |
| Merged-PR query | 1, plus a page per 50 unbound merges (1 typical) |
| Tag refs | 1 per repo with an unbound merged PR, plus a page per 100 matching tags |
| `compare` (REST) | 1 per (unbound merged PR × **untested** candidate tag), hard-capped at 20 per poll |

Worst realistic case — panel held open an entire hour at 30 s, 3 repos mid-release — is 120 polls × (3 GraphQL
+ up to 20 REST) ≈ 360 GraphQL and up to 2,400 REST per hour. The REST figure is the *cap*, not the
expectation: it is only approached in the first polls after a release cut, because `comparedTags` makes every
negative durable, so subsequent polls test only genuinely new tags and settle near zero. Without both the cap
and the persisted negatives this number is unbounded. Idle (5 min) is ~12 polls/hr. Honour
`X-RateLimit-Remaining`; below 10% fall back to the idle interval, drop the comparison budget to zero, and
mark the footer.

### Linear

Auth: personal API key (Settings → API), read-only usage. Resolution is by full identifier via aliased
`issue(id:)` fields — see *Project grouping* in §2 for the query shape and for why the `issues(filter:)`
cross-product form is unsafe.

Cached indefinitely, refreshed on cache miss and once a day. Linear being down never blocks the GitHub list
from rendering: cached mappings keep their headings, only uncached identifiers fall to `Other`, and the
Linear source is marked stale.

### Storage

- `~/Library/Application Support/PRStackMonitor/state.json` — dismissed set, snooze deadlines, read
  digests, PR→tag bindings, **unbound merged PRs with their merge commit and `mergedAt`**, Linear project
  cache, per-source last successful sync. Atomic writes, schema-versioned.
  The store that writes this file lands in **M6**, not M7 — see §7.
  **One writer.** `LocalState` is a single value owned by the main actor and written whole, so the release
  tracker hands its bindings back to be merged there rather than writing the file from its own task — two
  writers holding partial copies is how a dismissal disappears behind a binding. A file that fails to decode,
  or carries a schema version this build does not know, is **renamed aside** — `state.corrupt-<stamp>.json` —
  before the app starts from empty. Same forgiving spirit as the per-key policy in `LocalState.init(from:)`,
  but a whole-file failure has to move the original out of the way first: starting from empty and then saving
  over the file in place would destroy state nothing else can supply. Only part of it re-derives. Bindings and
  unbound merges come back from the next poll — except a merge older than the query's 14-day cold-start floor,
  which stays stranded (§3). `readDigests` and `snoozedUntil` are local-only: a lost digest set costs one burst
  of false unread and self-corrects at the next open, and a lost snooze just wakes its row early. Dismissal
  tombstones are the one loss nothing re-derives: every dismissed pull request the queries still return —
  anything still open, and merges inside the window — stops being suppressed, and the set cannot be rebuilt.
- Keychain (generic password, one item per service) — GitHub token, Linear key.
- `UserDefaults` — repo scope mode + selected repos, **per-repo tag pattern map** (`nameWithOwner` → glob,
  default `v*`), poll intervals, launch-at-login, per-event sink toggles. M6 reads the tag pattern map
  directly, with `v*` as the default; M7 adds the editor for it.

---

## 4. Sync engine

Adaptive polling (PRD §9), driven by one state machine, never by scattered timers. Several conditions are
true at once most of the time, so the table is **strictly ordered — first match wins**, top to bottom:

| # | Condition | Interval |
| --- | --- | --- |
| 1 | Display or system asleep | suspended |
| 2 | On battery below threshold (default 20%) | 15 min |
| 3 | Panel open | 30 s |
| 4 | Merged PR awaiting a release tag | 60 s |
| 5 | Recently active (any change in last 15 min) | 2 min |
| 6 | Idle | 5 min |

The two power conditions outrank everything, including an open panel: a sleeping machine polls nothing, and a
low battery is not worth a 30-second loop no matter what's on screen. Below those, the fastest applicable
interval wins by virtue of ordering — panel-open beats release-waiting beats recent-activity beats idle.

**Manual refresh** syncs immediately and restarts the current interval's timer from zero; it never changes
which interval applies. **Reconnecting** a source does the same, and additionally clears that source's
backoff. Waking from sleep syncs immediately, then re-evaluates the table from the top.

Sleep and wake need **two** subscriptions, since the conditions differ:

- System sleep — `NSWorkspace.notificationCenter`, `willSleepNotification` / `didWakeNotification`.
- Display sleep — `NSWorkspace.notificationCenter`, `screensDidSleepNotification` /
  `screensDidWakeNotification`. `willSleep` does not fire when only the display sleeps, so without this the
  app keeps polling at full rate against a dark screen.

Power source via `IOPSCopyPowerSourcesInfo`. On wake, if the last successful sync is older than the current
interval the footer reads `stale · last synced 41m ago` rather than showing the data as fresh.

### Failure handling — per source, not global

Connection state and last-success timestamps are held **per integration** (`github`, `linear`), never as one
global flag. Exponential backoff with jitter on 5xx/network, tracked per source.

A `401` marks **only that source** disconnected and raises its reconnect banner over that source's last known
data (design `1e`) — never over an empty panel. Concretely: an expired Linear key leaves every GitHub row
rendering normally, with cached project headings (§2) and a Linear-specific banner; an expired GitHub token
raises the GitHub banner over the last known list while Linear stays healthy and irrelevant. The menu bar's
`disconnected` glyph appears when **GitHub** is disconnected, since that's the source the panel's contents
actually depend on; Linear alone being down is a footer/staleness condition, not an icon state.

---

## 5. UI implementation

### Menu bar icon

A single template-ish `NSImage` redrawn on state change. Priority (highest wins), per PRD §4 and `1f`:

| # | State | Drawing |
| --- | --- | --- |
| 1 | Disconnected (GitHub) | Dashed glyph outline at reduced opacity |
| 2 | Action needed | Glyph + red circular badge, top-right, count centred, 1.5pt background halo |
| 3 | Unread | Glyph + indigo dot |
| 4 | Idle | Plain glyph |

**Disconnected outranks everything**, which is a change from the PRD's ordering and deliberate. Every other
state is derived from data that is, by definition, stale while GitHub is unreachable: a red badge counting
three cached failures asserts something the app cannot currently verify, and the PRD's own rule (§4) is that
the app never silently shows stale data as fresh. A dashed glyph over cached rows is the honest reading. The
panel still shows the last known list under a reconnect banner — the badge disappears from the menu bar, not
the information from the panel. Only **GitHub** disconnection does this; Linear being unreachable is a footer
staleness condition (§4).

The design's fifth state — amber pulsing "deploy in flight" — has no data source under tags-only tracking
(§3) and is not built. The drawing code keeps the case so a future `DeploymentAPITracker` can light it up.

Monochrome-safe by construction: badge **shape and position** differ per state, not just colour, so it
survives dark menu bars and reduced-colour settings. Verify against `Increase contrast` and
`Differentiate without colour`. Opening the panel clears unread; it never clears action-needed.

### Panel

440 pt content width, height to content up to 800 pt, then scrolls. Structure, top to bottom: header
(`Pull requests` · `10 in review · 3 shipping` · refresh · overflow menu) → scrolling body → footer (sync
dot, `synced 34s ago`, `Mark all read`, `Settings`).

**Row** (`PRRow`), left to right, matching 2a exactly:

- 5 pt unread gutter — indigo dot when unread, empty otherwise; **always reserved** so rows never shift.
- 16 pt status chip, 5 pt corner radius, tinted background with a 6 pt dot inside; when the row is tinted
  the chip carries a 3 pt halo in the row's own tint (this is what lets the spine pass behind it cleanly).
- Spine: 1.5 pt hairline at the chip's centre line, drawn from `top: -8` and/or `bottom: -8` depending on
  the member's position in the run. Top member draws downward only, base member upward only.
- Title, 12.5 pt, single line, ellipsis; weight 500 → 560 as the row gains urgency.
- Meta line, 11 pt: Linear identifier (indigo, clickable) with a `+N` affix when the PR resolves more than
  one ticket — `BIL-312 +2`, the affix in tertiary grey so it reads as a count, not a second link — repo name
  **only when the list spans more than one repo**, `#number`, **one** status phrase, age. When
  `primaryIssue` is nil the identifier token is **omitted entirely** — no placeholder, no `Other` label — and
  the line simply starts at the repo name or `#number`. This matches design 2a, where the Other-section row
  reads `#4051 · merge conflict · 2d`. The section heading already says `Other`; repeating it per row would
  spend the meta line's scarcest asset on the absence of information. Clicking the
  identifier opens the primary issue; clicking `+N` opens a small menu listing every linked ticket with its
  project, each opening in the browser. The status phrase is the only coloured *status* token —
  the identifier's indigo is a link affordance, not a state signal, which is why it's the one other colour
  permitted here. The repo name is tertiary: same grey as `#number`, no colour, and it truncates before the
  number does.
- Reviewer avatars, 18 pt circles, −2 pt overlap, each with a 1 pt row-tint halo and a 3 pt ring in that
  reviewer's state colour. Overflow becomes a count.
- Release track: three 9×3 pt segments, 2 pt gap. Segment 1 carries **CI** state (green/red/amber/grey),
  segment 2 fills on merge to trunk, segment 3 fills when a matching tag contains the merge commit. No pulse
  (§3).

Done rows add a trailing ✕; the section header adds `Clear all`.

### Keyboard actions on the hovered row

No global hotkey for opening the panel. Once it's open, the row under the pointer is the action target:

| Key | Action |
| --- | --- |
| `R` | Mark this row read |
| `X` | Dismiss (Done rows only) |
| `S` | Snooze — opens the duration menu inline |
| `↩` | Open the PR in the browser (same as click) |
| `L` | Open the Linear issue — the primary one; repeat presses cycle through the rest when a PR links several. No-op when the row has none |

Implementation notes, because this is fiddlier than it looks:

- A status-item `NSPopover` doesn't receive key events unless the app is active. Call
  `NSApp.activate()` when opening and let the popover's `transient` behaviour close it on resign — this is
  the standard arrangement and doesn't change dismissal feel.
- Track hover with `.onContinuousHover` on the row, holding the hovered `PRID` in the panel's view model.
  Intercept keys with a local `NSEvent` monitor scoped to the popover's window, not a global monitor.
- **`L` cycling state is `(PRID, index)`, stored as one optional pair, not a bare index.** Each press opens
  `linearIssues[index]` and advances; cycling **wraps** back to the primary after the last. The pair resets to
  nil whenever the hovered row changes and whenever the popover closes, so a press on a freshly hovered row
  always opens *its* primary. Storing the index alone would carry position across rows — hover a PR with three
  tickets, press `L` twice, hover a different PR, and the next press opens that row's third ticket, or nothing
  if it has fewer.
- **Own the monitor's lifecycle through one idempotent helper.**
  `addLocalMonitorForEvents(matching:handler:)` returns a token that stays live until removed. Store it in a
  single optional property and route *every* teardown — popover close, resign, and re-registration — through
  one `stopMonitor()`:

  ```swift
  private var keyMonitor: Any?

  private func stopMonitor() {
      guard let token = keyMonitor else { return }   // already stopped
      keyMonitor = nil                               // clear BEFORE removing
      NSEvent.removeMonitor(token)
  }
  ```

  Clearing the property before the call is what makes it safe to invoke twice, and close and resign do both
  fire for the same dismissal — so any teardown written inline at each call site would double-remove, which
  over-releases. `startMonitor()` calls `stopMonitor()` first, so a re-open can never stack a second monitor.
  Getting this wrong in the other direction — never removing — leaks a monitor per open and keeps every
  previous handler live, so the third open of the panel would dismiss three rows on one `X`.
- Every key action must also exist as a pointer affordance (the ✕, the row menu). The keyboard is an
  accelerator, never the only path.
- Hovered-row highlight is a subtle raise of the row background, distinct from the attention tint — an
  attention row must still read as an attention row while hovered.

### Design tokens (extracted from `Tray App.dc.html`, iteration 2a)

Define once in `PanelUI/Tokens.swift`, both appearances. Light values below are literal from the design;
dark is derived and reviewed against the same file's palette intent.

| Token | Light |
| --- | --- |
| Panel field / header / footer | `#F5F5F6` / `#F0F0F1` |
| Text primary / secondary / tertiary | `#1D1D1F` / `#57606A` / `#8A8F98` |
| Section heading | `#3C4149`, 11.5 pt, weight 640 |
| Danger | `#CF222E` on `#FFD5D1` chip, row tint `#FBE9E8` |
| Success | `#1A7F37` on `#BCECC9` chip, row tint `#E8F6EB` |
| In-flight / attention-amber | `#9A6700` |
| Merged, awaiting release | `#8250DF` on `#E6D4FA` chip |
| Accent / unread / Linear links | `#5E6AD2`, row tint `#ECECF8` |
| Neutral chip / spine / empty segment | `#E0E1E5` / `#DDDEE3` / `#E4E4E7` |
| Row geometry | padding `6 10 6 8`, margin `0 6`, radius 7, gap 9 |

Typography rules from PRD §11, enforced in review: **no monospaced type anywhere**; every numeral run uses
tabular figures (`.monospacedDigit` on the system font, which is *not* a monospaced face); project headings
are plain text with no colour — colour means status and nothing else.

### States to build

Three, not the design's five: **needs-attention** (default), **all-clear** (`Everything's clear` — a stated
message, not an empty list), and **first-run / disconnected** (`1e`: the connect prompt, and the expired-token
banner over cached data).

Dropped: *deploy in flight* has no data source (§3). *Heavy load with collapsed stacks* is out — **nothing
collapses**. Stacks always render as full runs, projects always render expanded, and a long list simply
scrolls. This removes the collapsed-stack summary row, the expand/collapse state, the auto-collapse
threshold, and the per-member segment bar from `1d`/`1f-C`. The panel stays one uninterrupted scroll at every
list length, which is what makes position stability (PRD §5.1) actually hold — a row never moves because
something above it folded.

Consequence worth keeping in view: at 20+ PRs the user scrolls to reach the bottom sections. That's accepted.
If it ever stops being acceptable, the honest fix is the collapsed summary row from `1f-C`, and it can be
added without disturbing anything else.

---

## 6. Testing

- **Fixture-driven derivation tests** (the bulk). Fixtures in `Tests/Fixtures/` are **synthetic by default** —
  hand-written JSON in the shape of the API responses, with invented repos, logins, titles and identifiers.
  Recording a real response is a fallback for getting a shape right, and anything recorded must be fully
  anonymised before it is committed: PR titles, branch names, repo names, `nameWithOwner`, URLs, Linear
  identifiers, reviewer logins, avatar URLs, and tokens. These fixtures describe private repositories, so
  scrubbing only credentials would still commit the contents of the user's work to a public repo.
  Each PRD edge case (§10) is a named fixture: no Linear issue, draft flip, out-of-order merge, never-tagged
  release, empty state, multi-repo list (repo name appears) and single-repo list (it doesn't), plus the stack
  cases named in §2 and `release-tag-on-later-page`, `linear-cross-team-number-collision`,
  `pr-multiple-issues-same-project`, `pr-multiple-issues-cross-project`, `stack-spanning-projects`,
  `snooze-status-changed-while-asleep`, `snooze-expiry-no-underlying-change`,
  `linear-resolve-order-cache-vs-fresh`, `release-compare-not-repeated-across-polls`,
  `release-annotated-tag-on-older-commit`, `pr-body-only-identifier`, and the two closed PR variants from the
  precedence table. Rollback-after-Done is not fixtured — it's undetectable under
  tags-only tracking (§3).
- **Golden panel models.** Assert the full derived `PanelModel` against a checked-in snapshot — catches
  ordering regressions, which are the ones a human reviewer will miss.
- **Invariant tests.** Attention ⇒ tinted ⇒ non-green icon. Section order stable across re-derivation with
  unchanged inputs. Unread never set by our own writes.
- **Icon state machine** — table test over the priority order, including "opening clears unread but not
  action-needed".
- **Event diffing** — assert the exact `[DomainEvent]` emitted between two consecutive snapshots. This is
  what a future notification sink depends on, so it's worth pinning before the sink exists.
- **HTTP layer** via a `URLProtocol` stub; no network in tests.
- **CI**: `swift test` on the three portable modules. These need no macOS, so they can run in this repo's
  Linux container once a toolchain is added; the AppKit target builds on a Mac only.

---

## 7. Milestones

Each is independently demoable. Estimates assume one engineer working in focused blocks.

| # | Milestone | Contents | Done when |
| --- | --- | --- | --- |
| **M0** | Skeleton & local build | SwiftPM package + Xcode app target, `LSUIElement`, self-signed local identity, `make run`, empty popover | A signed-to-run-locally menu bar app opens an empty popover; keychain access doesn't re-prompt across rebuilds |
| **M1** | Core model | Entities, `RowStatus` precedence (terminal states first), stack derivation, deterministic run/section ordering, snooze suppression, fixtures + golden tests | `derive()` turns a fixture snapshot into the exact 2a panel model; every stack fixture in §2 has a golden |
| **M2** | GitHub ingestion | GraphQL client with search pagination, repo scope modes, DTO→domain mapping (including nullable `body`), token in Keychain, ETag and point-budget rate limiting | Real PRs appear in a debug dump under both All and Selected scope, including past the first page of 50 |
| **M3** | Panel UI | Tokens, `PRRow`, spine, sections, header/footer, needs-attention + all-clear states | Panel is pixel-comparable to 2a against real data |
| **M4** | Icon + unread + events | Status item drawing (4 states, disconnected outranking), effective-state event diffing against `previous`, `EventSink` bus, digest-based unread, open/mark-all-read | Icon tracks the priority table, and an expired GitHub token shows dashed rather than a cached badge; a relaunch emits no events but preserves unread |
| **M5** | Linear grouping | Multi-identifier extraction, primary-issue selection, per-identifier `issue(id:)` resolution, cache, `Other` fallback | Rows group under real project headings; a multi-ticket PR shows `+N` and groups under its primary; a Linear outage keeps cached headings and marks the source stale |
| **M6** | Release tracking & persistence | The `state.json` store (atomic, schema-versioned), merge-commit capture, unbound-merge persistence, paginated tag polling by per-repo pattern, containment via `compare` with durable negatives and a per-poll budget, binding cache, third segment + Done section | A merged PR flips to shipped when a matching tag appears — including a tag cut weeks later, and one found past the first page; the binding, and everything else in `LocalState`, survives a relaunch |
| **M7** | Interactions & settings | Click-through, issue link, dismiss, `Clear all`, snooze, refresh, hovered-row keyboard actions with monitor teardown, Settings (tokens, repo scope, per-repo tag pattern editor, per-event toggles) | Every row in PRD §8 works by pointer *and* by key; ten open/close cycles fire each action exactly once; a dismissal and a snooze set before a relaunch are still in force after it |
| **M8** | Sync & resilience | Ordered interval table, display *and* system sleep, battery, staleness, per-source connection state and reconnect banners, backoff | Laptop sleeps overnight and wakes to correct, visibly-fresh state; an expired Linear key leaves GitHub rows intact |
| **M9** | Polish | Dark appearance, accessibility pass, long-list scroll performance | VoiceOver reads each row's state; contrast and reduced-colour verified; 25-PR fixture scrolls at 60fps |

M0–M4 is the useful core: an app that tells you when something needs you. M6 is the other half of the
product's promise and shouldn't slip past M8.

### Why persistence sits in M6 rather than M7

The milestones run in the order above, sequentially. The one adjustment against the obvious reading is that
the `state.json` store belongs to **M6**, even though the rest of what it holds — dismissals, snoozes, read
digests — is M7's material.

M6's headline behaviour requires it. "A tag cut weeks later still binds" means the unbound merge has to
survive relaunches, and the merged-PR query's lower bound is *dynamic*: it starts at the oldest unbound
merged PR still in local state (§3). Without a store, every launch falls back to the 14-day default, the
unbound merge ages out of the query, its merge commit is lost, and the row strands at
`merged · awaiting release` permanently — the exact failure the dynamic bound exists to prevent. Durable
`comparedTags` degrades more gently, costing rate limit rather than data, but it wants the same file.

So M6 builds the store and persists what it needs; M7 writes its own keys through the store that already
exists. Nothing else moves. In particular the **Settings window stays in M7**: the per-repo tag pattern is a
`UserDefaults` map with `v*` as the default, so M6 reads the key and M7 adds the editor. Confirm early that
the target repos actually tag `v*` (§8) — without the editor, that assumption is what keeps M6 demoable.

One consequence for scheduling: M6 and M7 cannot be built in parallel *until* the store lands, since both
write `LocalState` and its `Codable`. Once it has, the remainder of M7 is pure app-layer work — panel views,
row affordances, the hover key monitor — and touches neither `GitHubKit` nor `PRStackCore`.

---

## 8. Decisions (PRD §12, resolved)

1. **Notification on reaching production** — not built, but the extension must be cheap. Hence the event bus
   in §1: v1 ships one sink, a notification sink drops in later without touching core.
2. **Keyboard** — no shortcut for opening the panel. Keyboard actions on the **hovered row** (mark read,
   dismiss, snooze, open), spec'd in §5.
3. **Repository name in the row** — yes, shown when the list spans more than one repo.
4. **Auto-collapse** — no collapsing at all, of stacks or projects. Scrolling is fine. Removed from §5 and M9.
5. **Repo scope** — switchable: all repos, or a selected subset. §3.
6. **Trunk and tags** — trunk is each repo's default branch, read not configured. Releases are tags matching
   a glob, stored **per repository** with `v*` as the default.
7. **Deploy tracking** — tags only, outcome ignored. Shipped = merge commit is contained in a matching tag.
   §3 spells out what this removes (deploy-in-flight, deploy-failed, rollback detection) and the
   `ReleaseTracker` seam that would restore it.

Nothing is blocked on further input. The one thing to confirm during M6 is that the target repos actually
tag releases with a stable pattern — if some repo tags irregularly, its merged PRs sit at "merged · awaiting
release" indefinitely, which per PRD §10 is quiet by design and not an error state.

---

## 9. Repository layout

```text
PRStackMonitor/
  Package.swift                 # PRStackCore, GitHubKit, LinearKit (+ tests)
  Sources/
    PRStackCore/                # models, derivation, ordering, unread, snooze
    GitHubKit/                  # GraphQL + REST, DTOs, rate limiting
    LinearKit/                  # issue → project
  Tests/
    PRStackCoreTests/           # fixtures + golden panel models
    GitHubKitTests/             # URLProtocol-stubbed
  App/
    PRStackMonitor.xcodeproj    # signing: "Sign to Run Locally", team: None
    Sources/
      AppDelegate.swift         # NSStatusItem, NSPopover lifecycle
      StatusItemController.swift# icon drawing + state machine
      SyncEngine/               # scheduling, power, staleness
      Events/                   # EventBus + sinks (unread today, notifications later)
      PanelUI/                  # Tokens.swift, PanelView, PRRow, StackSpine, Sections, HoverKeys
      Settings/                 # tokens, repo scope, tag pattern
  Makefile                      # build, sign, install to /Applications, run
docs/IMPLEMENTATION_PLAN.md     # this file
design/                         # PRD + design iterations (unchanged)
```
