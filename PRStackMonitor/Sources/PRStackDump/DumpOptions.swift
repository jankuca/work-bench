import Foundation
import GitHubKit

/// A message meant for the user, not a stack trace.
struct DumpFailure: Error {
    var message: String

    init(_ message: String) {
        self.message = message
    }
}

let usage = """
usage: prstack-dump <snapshot.json> [--now 2026-01-10T12:00:00Z]
       prstack-dump --github [--repo owner/name ...] [options]

Reads a snapshot, derives it, and prints the panel. Both renderings are the ones the
golden tests compare, so dumping a fixture reproduces that fixture's golden byte for byte.

Rendering

  --presentation        Print the panel as the view shows it — the phrase, meta line,
                        release track and section headings per row — instead of the
                        derived model. This is the layer M3's row view reads.

Snapshot file

  <snapshot.json>       { "now": …, "snapshot": { … }, "local": { … } }
                        The fixtures under Tests/PRStackCoreTests/Fixtures are exactly
                        this shape, so any of them can be dumped directly.

Live GitHub

  --github              Fetch from GitHub instead of reading a file.
  --repo owner/name     Restrict to this repository. Repeatable; without it the scope is
                        every repository the viewer authors pull requests in.
  --qualifier <q>       Append a raw search qualifier, e.g. --qualifier is:open.
                        Repeatable.
  --page-size N         Search page size, 1–100 (default 50). Set it low to watch
                        pagination run past the first page on a small account.
  --page-cap N          Stop after N pages (default 10).
  --point-budget N      GraphQL points this poll may spend (default \(PointBudget.defaultPoints)).
  --token <value>       The token to use. Otherwise $PRSTACK_GITHUB_TOKEN, then
                        $GITHUB_TOKEN, then the login keychain on macOS.
  --emit-snapshot <p>   Also write the fetched snapshot to <p> as JSON, or to stdout for
                        `-`. The file is dumpable again, so a live fetch can become a
                        fixture once it has been anonymised.

Releases and persistence (with --github)

  --releases            Also run release tracking: a second search for closed pull
                        requests, bounded by the oldest merge still waiting for a tag, then
                        the repository's tags and a `compare` per untested candidate. This
                        is what flips a merged row to shipped.
  --tag-pattern <r=g>   The release tag glob for one repository, e.g.
                        --tag-pattern acme/billing=release-*. Repeatable; anything unlisted
                        uses \(TagPatterns.defaultPattern).
  --comparisons N       `compare` calls this poll may spend (default 20). The rest defers to
                        the next poll, and nothing already tested is ever re-tested.
  --state <path>        Read and write state.json at <path> — dismissals, snoozes, read
                        digests, release bindings and unbound merges. Without it the state
                        is in memory and every run starts cold; with it, running twice is
                        how you watch a binding survive a relaunch.

Linear (with --github)

  --linear-token <v>    The Linear API key. Otherwise $PRSTACK_LINEAR_KEY, then
                        $LINEAR_API_KEY, then the login keychain on macOS.
  --no-linear           Skip resolution entirely. Every row falls under `Other`, which is
                        what the panel looks like with no Linear key configured.
  --linear-cache <p>    Read and write the identifier → project cache at <p>. Without it
                        the cache is in memory and every run resolves from scratch; with
                        it, running twice shows the second run answering from cache.

Both

  --now <timestamp>     Override the clock. Snooze expiry and everything else
                        time-dependent is a pure function of this, so moving it is how
                        you watch a snoozed row wake up.
"""

struct DumpOptions {
    enum Source {
        case file(String)
        case github
    }

    var source: Source = .github
    var now: Date?
    var repositories: [String] = []
    var qualifiers: [String] = []
    var pageSize = 50
    var pageCap = 10
    var pointBudget = PointBudget.defaultPoints
    var token: String?
    var emitSnapshotPath: String?
    var rendersPresentation = false
    var linearToken: String?
    var linearCachePath: String?
    var resolvesLinear = true
    var tracksReleases = false
    var tagPatterns: [String: String] = [:]
    var comparisonBudget = 20
    /// Whether `--comparisons` was actually typed. The value alone cannot say: 20 is both
    /// the default and a perfectly ordinary thing to pass, so without this the validation
    /// below would either miss the flag or reject the default.
    var setsComparisonBudget = false
    var statePath: String?

    /// No `--repo` means every repository, which is the `all` mode from
    /// IMPLEMENTATION_PLAN §3 rather than an empty selection.
    var scope: RepoScope {
        repositories.isEmpty ? .all : .selected(repositories)
    }

    static func parse(_ arguments: [String]) throws -> DumpOptions {
        var options = DumpOptions()
        var path: String?
        var wantsGitHub = false
        var index = arguments.startIndex

        func next(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.endIndex else {
                throw DumpFailure("\(flag) needs a value")
            }
            return arguments[index]
        }

        // Every numeric option here is a bound, and every one of them is meaningless at
        // zero or below. `GitHubClient.Configuration` quietly clamps two of them, which
        // would leave the user's value silently ignored; `--point-budget -5` is not
        // clamped at all and reports "spent 0 of -5 GraphQL point(s)". Reject at the door.
        func nextInt(_ flag: String) throws -> Int {
            let raw = try next(flag)
            guard let value = Int(raw) else {
                throw DumpFailure("\(flag) needs a whole number, got '\(raw)'")
            }
            guard value > 0 else {
                throw DumpFailure("\(flag) needs a positive whole number, got '\(raw)'")
            }
            return value
        }

        while index < arguments.endIndex {
            switch arguments[index] {
            case "--github":
                wantsGitHub = true
            case "--repo":
                options.repositories.append(try next("--repo"))
            case "--qualifier":
                options.qualifiers.append(try next("--qualifier"))
            case "--page-size":
                options.pageSize = try nextInt("--page-size")
            case "--page-cap":
                options.pageCap = try nextInt("--page-cap")
            case "--point-budget":
                options.pointBudget = try nextInt("--point-budget")
            case "--token":
                options.token = try next("--token")
            case "--linear-token":
                options.linearToken = try next("--linear-token")
            case "--linear-cache":
                options.linearCachePath = try next("--linear-cache")
            case "--no-linear":
                options.resolvesLinear = false
            case "--releases":
                options.tracksReleases = true
            case "--comparisons":
                options.comparisonBudget = try nextInt("--comparisons")
                options.setsComparisonBudget = true
            case "--state":
                options.statePath = try next("--state")
            case "--tag-pattern":
                let raw = try next("--tag-pattern")
                // `=` rather than a repeated pair of arguments, so one repository's setting
                // is one token and cannot be split by a missing value.
                //
                // The repository half is validated as `owner/name` rather than taken as
                // typed: `TagPatterns` keys on `nameWithOwner`, so `billing=release-*` would
                // be stored, never matched, and silently leave that repository on `v*` —
                // which looks exactly like the pattern being wrong.
                guard let separator = raw.firstIndex(of: "="),
                      separator != raw.startIndex,
                      raw.index(after: separator) != raw.endIndex,
                      RepoScope.isWellFormed(String(raw[..<separator])) else {
                    throw DumpFailure("--tag-pattern needs owner/name=glob, got '\(raw)'")
                }
                options.tagPatterns[String(raw[..<separator])] = String(raw[raw.index(after: separator)...])
            case "--emit-snapshot":
                options.emitSnapshotPath = try next("--emit-snapshot")
            case "--presentation":
                options.rendersPresentation = true
            case "--now":
                let raw = try next("--now")
                guard let parsed = ISO8601DateFormatter().date(from: raw) else {
                    throw DumpFailure("--now needs an ISO 8601 timestamp such as 2026-01-10T12:00:00Z")
                }
                options.now = parsed
            case "-h", "--help":
                print(usage)
                exit(0)
            case let argument where argument.hasPrefix("-"):
                throw DumpFailure("unknown option '\(argument)'\n\n" + usage)
            case let argument:
                guard path == nil else { throw DumpFailure("expected a single snapshot path\n\n" + usage) }
                path = argument
            }
            index += 1
        }

        // Naming both a file and `--github` is ambiguous rather than harmless: the two
        // sources produce different panels, and silently preferring one would make the
        // other's flags look ignored.
        switch (path, wantsGitHub) {
        case (let path?, false):
            options.source = .file(path)
        case (nil, true):
            options.source = .github
        case (nil, false):
            throw DumpFailure(usage)
        case (.some, true):
            throw DumpFailure("pass either a snapshot path or --github, not both")
        }

        if case .file = options.source {
            let liveOnly = [
                options.repositories.isEmpty ? nil : "--repo",
                options.qualifiers.isEmpty ? nil : "--qualifier",
                options.token == nil ? nil : "--token",
                options.emitSnapshotPath == nil ? nil : "--emit-snapshot",
                options.linearToken == nil ? nil : "--linear-token",
                options.linearCachePath == nil ? nil : "--linear-cache",
                // A fixture carries its issues already resolved, so there is nothing for
                // this to switch off — quietly accepting it would suggest otherwise.
                options.resolvesLinear ? nil : "--no-linear",
                options.tracksReleases ? "--releases" : nil,
                options.tagPatterns.isEmpty ? nil : "--tag-pattern",
                options.setsComparisonBudget ? "--comparisons" : nil,
                // A fixture carries its own `local`, including its release bindings, so a
                // state file would be two answers to the same question.
                options.statePath == nil ? nil : "--state"
            ].compactMap { $0 }
            if !liveOnly.isEmpty {
                throw DumpFailure("\(liveOnly.joined(separator: ", ")) only applies with --github")
            }
        }

        // The release path runs two searches of its own — open, then closed and bounded by
        // the oldest unbound merge — so a raw qualifier would land on both and mean
        // different things in each.
        if options.tracksReleases && !options.qualifiers.isEmpty {
            throw DumpFailure("--qualifier cannot be combined with --releases")
        }
        // Both of these configure work that only `--releases` does. Accepting them quietly
        // would report a budget that was never spent and a pattern that was never used.
        if !options.tracksReleases && !options.tagPatterns.isEmpty {
            throw DumpFailure("--tag-pattern only applies with --releases")
        }
        if !options.tracksReleases && options.setsComparisonBudget {
            throw DumpFailure("--comparisons only applies with --releases")
        }

        return options
    }
}
