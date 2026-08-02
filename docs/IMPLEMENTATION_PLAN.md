# PR Stack Monitor — Implementation Plan

Swift / macOS menu bar app. Source of truth for scope: [`design/PRD.dc.html`](../design/PRD.dc.html).
Source of truth for visuals: iteration **2a** at the top of [`design/Tray App.dc.html`](../design/Tray%20App.dc.html)
("Single scroll, stacks drawn as a spine"). The numbered iterations `1a`–`1f` below it are superseded,
except as a reference for states 2a doesn't draw: `1c` (release grouping), `1d` (collapsed stacks / heavy
load), `1e` (first run + expired token), `1f` (tray icon state set).

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
| `UNUserNotificationCenter` | Unreliable for non-notarized bundles; can fail to register | Defer notifications (PRD §12 lists them as open anyway). Menu bar icon is the only alert channel in v1 |
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

Six modules. The top three are pure Swift (Foundation only, no AppKit) so they build and test off-device.

```
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

```
poll tick ─► GitHubKit.fetch(repos)   ┐
            LinearKit.fetch(issueIds) ┼─► RawSnapshot ─► PRStackCore.derive(snapshot, localState, now)
            Persistence.load()        ┘                          │
                                                                 ├─► PanelModel  ─► PanelUI
                                                                 └─► IconState   ─► StatusItemController
```

`localState` = dismissed IDs, snooze deadlines, last-read digests, deploy bindings. Derivation is a pure
function of `(RawSnapshot, LocalState, Date)`; the same inputs always yield the same panel.

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
  var linearIssue: IssueRef?   // identifier + url, resolved by LinearKit
}

struct Stack { var members: [PRID] }        // ordered top-most first, base last
struct Release { var tag: String; var prs: [PRID]; var stage: DeployStage; var status: DeployStatus }
enum DeployStage { case preview, staging, production }
```

### Row status — single value, strict precedence

Each row resolves to exactly one `RowStatus`. First match wins:

1. `conflicted` — mergeable == conflicting → red
2. `changesRequested` — review decision → red
3. `checksFailing` — check rollup failing → red
4. `deployFailed` — bound release held or failed → red
5. `blocked(on: PRID)` — parent PR still open → neutral grey, meta reads `waiting on #NNNN`
6. `deploying` — bound release in flight → purple/amber
7. `merged` — merged, not yet at production → purple
8. `approved` / `readyToMerge` — green (`readyToMerge` when approved **and** checks green **and** mergeable)
9. `inReview` — default
10. `closed` — grey, Done section

Invariant from the PRD (§5.2): *a row that needs attention always has a matching icon; a green icon never
appears in a tinted row.* Encode this as a unit test over all `RowStatus` × tint combinations, not as a
convention.

**Attention** = statuses 1–4. That set drives the warm tint, the bolder title weight, and the red badge
count. Note 5 (`blocked`) is deliberately **not** attention — it's the layer below's problem.

### Stack derivation

Build `head → PR` index over the user's own open PRs; a PR's parent is the PR whose `headRef` equals this
PR's `baseRef`. Chains of length ≥ 2 become a `Stack`, rendered top-most first (walk to the leaf, emit
downward). Cases to handle explicitly, each with a fixture test:

- **Merged out of order** — merged parent drops out; children re-target trunk; spine reflows silently.
- **Fork (two PRs share a base)** — the design assumes a linear chain. Decision: the longest chain keeps
  the spine; sibling branches render as their own runs directly beneath. No error state.
- **Cycle** — impossible in git but cheap to guard: visited-set, break and treat as loose PRs.
- **Parent in another repo / not authored by user** — not a stack; row shows normally.

### Project grouping (Linear)

Resolve an issue identifier per PR, in order: (1) branch name match `([A-Z][A-Z0-9]+-\d+)`, (2) PR title
prefix, (3) `linear.app/…/issue/XXX-123` URL in the body. Then batch-resolve identifiers → project via
Linear's GraphQL. No identifier, or an issue with no project → **Other**. Cache the mapping on disk; issues
rarely change project, so this is one cheap query per new identifier.

Section order: projects by most recent activity among their PRs, then `Other`, then `Done`. **Within a
section, order is stable** — stacks first (as runs), then loose PRs by PR number descending. Never re-sort
by urgency (PRD §5.1).

### Unread

Per PR, store a digest of `(reviewDecision, checkRollup, mergeable, commentCount, lastCommentAt, releaseStage)`
at the moment the panel was last open. Unread = digest differs. Opening the panel rewrites all digests;
`Mark all read` does the same on demand. Dismissal (Done rows) is permanent — a tombstone set that
suppresses the PR forever, even if a later event touches it (PRD §5.3).

---

## 3. Data sources

### GitHub

Auth: **fine-grained personal access token**, pasted in Settings, scopes read-only (`Contents: read`,
`Pull requests: read`, `Actions: read`, `Deployments: read`, `Metadata: read`). No OAuth app, no callback
URL, no Apple involvement. Device Flow can replace this later without touching the sync layer — hide it all
behind a `TokenProvider`.

One GraphQL query per repo per poll returns everything the list needs:

```graphql
search(query: "is:pr author:@me -is:draft repo:OWNER/NAME", type: ISSUE, first: 50) {
  nodes { ... on PullRequest {
    number title url headRefName baseRefName isDraft state createdAt updatedAt
    mergeable  reviewDecision  mergeCommit { oid }  comments { totalCount }
    reviews(last: 20) { nodes { author { login avatarUrl } state submittedAt } }
    commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first:20){ ... } } } } }
  } }
}
```

Merged PRs are fetched with a second, narrower query bounded to the last 14 days — enough to follow a
release to production without unbounded history.

**Deploy tracking** (PRD §7) is REST, because it's cheap and conditional-request friendly:

1. On merge, record `mergeCommit.oid`. Fallback if absent (squash rewrote history): match `(#NNNN)` in
   recent trunk commit messages.
2. Poll `GET /repos/{o}/{r}/tags` (ETag-cached). For each new tag, test containment with
   `GET /repos/{o}/{r}/compare/{tag}...{sha}` → `status` of `identical` or `behind` means the tag contains
   the commit. Bind PR → release; cache the binding permanently.
3. Poll `GET /repos/{o}/{r}/deployments?ref={tag}` and each deployment's `/statuses`. Map environment names
   (configurable, default `staging` / `production`) to stages; map `success` / `failure` / `in_progress` to
   the segment states. Fallback when the repo doesn't use the Deployments API: watch workflow runs whose
   `head_branch` is the tag (`GET /repos/{o}/{r}/actions/runs?event=push&branch={tag}`).
4. Releases carry several PRs — they advance together, which is exactly the `1c` release grouping.

Budget: GraphQL 5,000 points/hr, REST 5,000 req/hr. At 3 repos and the polling schedule in §4, steady state
is well under 500 req/hr. Honour `X-RateLimit-Remaining`; below 10% fall back to the idle interval and mark
the footer.

### Linear

Auth: personal API key (Settings → API), read-only usage. One query resolves identifiers to projects:

```graphql
issues(filter: { number: { in: [...] }, team: { key: { in: [...] } } }) {
  nodes { identifier url project { id name } }
}
```

Cached indefinitely, refreshed on cache miss and once a day. Linear being down degrades to everything in
`Other` — never blocks the GitHub list from rendering.

### Storage

- `~/Library/Application Support/PRStackMonitor/state.json` — dismissed set, snooze deadlines, read
  digests, PR→release bindings, Linear project cache, last successful sync. Atomic writes, schema-versioned.
- Keychain (generic password, one item per service) — GitHub token, Linear key.
- `UserDefaults` — repo list, environment names, trunk name, poll intervals, launch-at-login.

---

## 4. Sync engine

Adaptive polling (PRD §9), driven by one state machine, never by scattered timers:

| Condition | Interval |
| --- | --- |
| Panel open | 30 s |
| Deploy in flight | 60 s |
| Recently active (any change in last 15 min) | 2 min |
| Idle | 5 min |
| On battery below threshold (default 20%) | 15 min |
| Display asleep / system asleep | suspended |

Sleep and wake via `NSWorkspace.notificationCenter` (`willSleep` / `didWake`), power source via
`IOPSCopyPowerSourcesInfo`. On wake: immediate sync, and if the last successful sync is older than the
current interval the footer reads `stale · last synced 41m ago` rather than showing the data as fresh.

Failure handling: exponential backoff with jitter on 5xx/network; `401` flips global state to
`disconnected` and raises the reconnect banner over the **last known list** (design `1e`), never over an
empty panel. Any partial failure still renders — a Linear timeout must not blank the GitHub rows.

---

## 5. UI implementation

### Menu bar icon

A single template-ish `NSImage` redrawn on state change. Priority (highest wins), per PRD §4 and `1f`:

| State | Drawing |
| --- | --- |
| Action needed | Glyph + red circular badge, top-right, count centred, 1.5pt background halo |
| Deploy in flight | Glyph + amber dot, 1.4 s ease-in-out opacity pulse |
| Unread | Glyph + indigo dot |
| Idle | Plain glyph |
| Disconnected | Dashed glyph outline at reduced opacity |

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
- Meta line, 11 pt: Linear identifier (indigo, clickable), `#number`, **one** status phrase (the only
  coloured token), age.
- Reviewer avatars, 18 pt circles, −2 pt overlap, each with a 1 pt row-tint halo and a 3 pt ring in that
  reviewer's state colour. Overflow becomes a count.
- Deploy track: three 9×3 pt segments, 2 pt gap. Segment 1 carries **CI** state (green/red/amber/grey);
  segments 2 and 3 fill as the change advances; the active one pulses.

Done rows add a trailing ✕; the section header adds `Clear all`.

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
| Merged / deploying | `#8250DF` on `#E6D4FA` chip |
| Accent / unread / Linear links | `#5E6AD2`, row tint `#ECECF8` |
| Neutral chip / spine / empty segment | `#E0E1E5` / `#DDDEE3` / `#E4E4E7` |
| Row geometry | padding `6 10 6 8`, margin `0 6`, radius 7, gap 9 |

Typography rules from PRD §11, enforced in review: **no monospaced type anywhere**; every numeral run uses
tabular figures (`.monospacedDigit` on the system font, which is *not* a monospaced face); project headings
are plain text with no colour — colour means status and nothing else.

### States to build

All five from the design: needs-attention (default), all-clear (`Everything's clear`, not an empty list),
deploy in flight, heavy load with collapsed stacks, first-run/disconnected. Collapsed stacks (`1d`, `1f-C`)
are a **scaling affordance**, not the default: auto-collapse above a configurable open-PR count
(recommendation: 12 — see §8), summary row shows name, member count, one segment per member coloured by
state, and the position of the first blockage (`blocked at 3/4`).

---

## 6. Testing

- **Fixture-driven derivation tests** (the bulk). Record real GitHub/Linear JSON once into
  `Tests/Fixtures/`, scrub tokens and logins. Each PRD edge case (§10) is a named fixture: no Linear issue,
  draft flip, out-of-order merge, never-tagged release, rollback after Done, empty state.
- **Golden panel models.** Assert the full derived `PanelModel` against a checked-in snapshot — catches
  ordering regressions, which are the ones a human reviewer will miss.
- **Invariant tests.** Attention ⇒ tinted ⇒ non-green icon. Section order stable across re-derivation with
  unchanged inputs. Unread never set by our own writes.
- **Icon state machine** — table test over the priority order, including "opening clears unread but not
  action-needed".
- **HTTP layer** via a `URLProtocol` stub; no network in tests.
- **CI**: `swift test` on the three portable modules. These need no macOS, so they can run in this repo's
  Linux container once a toolchain is added; the AppKit target builds on a Mac only.

---

## 7. Milestones

Each is independently demoable. Estimates assume one engineer working in focused blocks.

| # | Milestone | Contents | Done when |
| --- | --- | --- | --- |
| **M0** | Skeleton & local build | SwiftPM package + Xcode app target, `LSUIElement`, self-signed local identity, `make run`, empty popover | A signed-to-run-locally menu bar app opens an empty popover; keychain access doesn't re-prompt across rebuilds |
| **M1** | Core model | Entities, `RowStatus` precedence, stack derivation, section ordering, fixtures + golden tests | `derive()` turns a fixture snapshot into the exact 2a panel model |
| **M2** | GitHub ingestion | GraphQL client, DTO→domain mapping, token in Keychain, ETag/rate-limit handling | Real PRs from the user's repos appear in a debug dump |
| **M3** | Panel UI | Tokens, `PRRow`, spine, sections, header/footer, needs-attention + all-clear states | Panel is pixel-comparable to 2a against real data |
| **M4** | Icon + unread | Status item drawing for all five states, digest-based unread, open/mark-all-read semantics | Icon tracks the PRD §4 priority table; unread clears correctly |
| **M5** | Linear grouping | Identifier extraction, project resolution, cache, `Other` fallback | Rows group under real project headings; Linear outage degrades to `Other` |
| **M6** | Deploy tracking | Merge-commit capture, tag containment, deployment statuses, release binding, deploy track + Done section | A merged PR advances preview → staging → production and lands in Done |
| **M7** | Interactions & persistence | Row click-through, issue link, dismiss, `Clear all`, snooze, refresh, Settings (tokens, repos, environments) | Every row in PRD §8 does what the table says; state survives relaunch |
| **M8** | Sync & resilience | Adaptive intervals, sleep/battery, staleness, reconnect banner, backoff | Laptop sleeps overnight and wakes to correct, visibly-fresh state |
| **M9** | Scale & polish | Collapsed stacks, collapsed projects, heavy-load state, dark appearance, accessibility pass | 14-PR fixture renders as `1d`; VoiceOver reads each row's state; contrast/reduced-colour verified |

M0–M4 is the useful core: an app that tells you when something needs you. M6 is the other half of the
product's promise and shouldn't slip past M8.

---

## 8. Open questions (PRD §12) — recommendations

1. **Notification on reaching production?** *No, not in v1* — and the no-account constraint makes the
   decision for us. Revisit if the amber→green transition proves easy to miss.
2. **Keyboard open-and-jump?** *Defer.* A global hotkey to open the panel is ~20 lines and worth adding at
   M9; arrow-key row navigation is not, for a pointer-driven popover.
3. **Repository name in the row?** Show it in the meta line **only when more than one repo is configured**,
   between the identifier and `#number`. Costs nothing when there's one repo.
4. **Auto-collapse threshold?** 12 open PRs, configurable. Below that the panel fits in 800 pt without
   scrolling past the fold, which is the actual constraint.

Additional decisions this plan needs from the user before M2/M6:

- Which repositories to watch (list, or "all repos I have push access to"?).
- Trunk branch name, deployment environment names, and tag pattern for releases.
- Whether the target repos use the GitHub Deployments API or only workflow runs — this picks the primary vs.
  fallback path in §3.

---

## 9. Repository layout

```
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
      PanelUI/                  # Tokens.swift, PanelView, PRRow, StackSpine, Sections
      Settings/                 # tokens, repos, environments
  Makefile                      # build, sign, install to /Applications, run
docs/IMPLEMENTATION_PLAN.md     # this file
design/                         # PRD + design iterations (unchanged)
```
