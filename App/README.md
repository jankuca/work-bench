# PRStackMonitor.app

The AppKit shell: an `NSStatusItem` and the `NSPopover` hanging off it. Everything that
decides *what* to show lives in [`../PRStackMonitor`](../PRStackMonitor); this package is
the part that needs a Mac.

```sh
make run
```

That compiles the executable, assembles `build/PRStackMonitor.app`, signs it, and
launches it. There is no Dock icon — look for the stack glyph in the menu bar and click
it. `make help` lists the rest.

## Why there is no .xcodeproj

The implementation plan's §9 sketches an Xcode project. This is a SwiftPM executable plus
a `Makefile` that assembles the bundle instead, because:

- the build is reproducible from the command line, and diffable — a `.pbxproj` is neither;
- nothing here needs Interface Builder, asset catalogs, or a build phase Xcode uniquely
  provides;
- `swift build` is the same toolchain CI already uses for the portable modules.

Xcode still works for editing and debugging — `xed App` opens the package directly, with
breakpoints and the view debugger intact. If a real project file is ever wanted (for
profiling templates, say), XcodeGen can generate one from a small `project.yml` without
changing any of this.

## One-time: the local signing certificate

Without a paid Apple Developer account the app is signed with a **self-signed certificate
created on this Mac**. This is not about Gatekeeper — a locally built app is never
quarantined. It is about the *designated requirement* staying constant across rebuilds.

An ad-hoc signature (`codesign -s -`) hashes the binary, so every rebuild produces a
different identity, and from M2 onwards macOS treats each build as a new app asking for
the GitHub token in the Keychain — a permission prompt on every single run. A stable
self-signed identity fixes the requirement once.

Create it once:

1. Open **Keychain Access**.
2. Menu → **Certificate Assistant** → **Create a Certificate…**
3. Name: `PRStackMonitor Local`
   Identity Type: **Self Signed Root**
   Certificate Type: **Code Signing**
4. Create, and accept the warning about it being self-signed.

Verify it is visible to `codesign`:

```sh
make identity
```

`PRStackMonitor Local` should appear in the list. `make run` picks it up automatically.

If it is missing, `make run` still works — it falls back to an ad-hoc signature and warns.
That is fine for M0, which stores nothing; it becomes an irritation at M2.

To use a different name: `make run SIGN_IDENTITY="Some Other Identity"`.

## App Sandbox

v1 ships **unsandboxed**, per IMPLEMENTATION_PLAN §0. Nothing here needs an entitlement
that would require a provisioning profile, so the sandbox can be switched on later
without redesign — but until there is a paid account it buys nothing and costs debugging
time, so there is no entitlements file.

## What M0 is, and is not

M0 is the shell: a menu bar item that opens an empty popover, built and signed by one
command. The popover deliberately shows a placeholder rather than a mock of design 2a —
a drawing with no data behind it invites design review of something that does not exist
yet.

The panel, its tokens and the row layout are M3. The data behind them is M2 (GitHub) and
M5 (Linear). The icon's four states are M4; the SF Symbol here is a stand-in.
