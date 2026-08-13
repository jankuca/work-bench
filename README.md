# PR Stack Monitor

A macOS menu bar app that watches your open pull requests — across repositories, stacked
or not — and tells you which one is actually waiting on you. Linear identifiers in a
branch or title are resolved to their issues, and merged work is tracked until it shows up
in a release tag.

## Running it

Requires macOS 14 or newer and a Swift 5.9 toolchain (Xcode 15+, or the Swift toolchain's
command line tools — `swift --version` should answer).

```sh
git clone https://github.com/jankuca/work-bench.git
cd work-bench
make run
```

That compiles the executable, assembles and signs `build/PRStackMonitor.app`, and launches
it. There is no Dock icon — look for the stack glyph in the menu bar and click it.

Without a GitHub token the panel shows the connect prompt; paste one in Settings, or set
`$PRSTACK_GITHUB_TOKEN`. A Linear key (`$PRSTACK_LINEAR_KEY`) is optional and only affects
identifier resolution.

`make run` signs ad-hoc unless a signing identity named `PRStackMonitor Local` exists on
this Mac. That works, but the signature changes on every rebuild, so macOS re-prompts for
Keychain access each run —
[`App/README.md`](App/README.md) has the one-time setup that fixes it.

## Other targets

`make help` lists them all. The ones worth knowing:

| Target | What it does |
| --- | --- |
| `make test` | run the portable core's tests |
| `make install` | copy the signed app to `/Applications` |
| `make panel` | print the panel from a fixture — no token, no network |
| `make fetch` | derive live GitHub + Linear data and print the panel |
| `make clean` | remove build products |

## Layout

- [`PRStackMonitor/`](PRStackMonitor/README.md) — the portable half: domain model,
  derivation, presentation, and the GitHub and Linear clients. Foundation only, tested in
  CI on Linux.
- [`App/`](App/README.md) — the AppKit shell: the status item, the popover, Settings, and
  the poll scheduler's macOS-facing half.
- [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) — the whole design.
