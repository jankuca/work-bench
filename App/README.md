# PRStackMonitor.app

The AppKit shell: an `NSStatusItem` and the `NSPopover` hanging off it. Everything that
decides *what* to show lives in [`../PRStackMonitor`](../PRStackMonitor); this package is
the part that needs a Mac.

The `Makefile` is at the repository root, so run these from there rather than from `App/`:

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
created on this Mac**. That buys a stable local signing identity and nothing more — not
notarization, not Gatekeeper approval.

It is also not what makes the app launchable. Build output isn't tagged with the
`com.apple.quarantine` attribute the way a downloaded app is, so Gatekeeper was never in
the way to begin with. (If a build ever *is* quarantined — say the tree was unpacked from
a downloaded archive that propagated the attribute — `xattr -dr com.apple.quarantine` on
the bundle clears it.)

What the certificate does buy is a *designated requirement* that stays constant across
rebuilds. An ad-hoc signature (`codesign -s -`) identifies a single binary by its code
hash, so every rebuild is a different identity, and from M2 onwards macOS treats each
build as a new app asking for the GitHub token in the Keychain — a permission prompt on
every single run. A stable self-signed identity fixes the requirement once.

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

v1 ships **unsandboxed**, per IMPLEMENTATION_PLAN §0.

Worth being precise about why, because the sandbox is easy to mis-file as an
Apple-account problem. **The App Sandbox needs no paid account**, and it does contain the
app for real. What needs a paid account is a *provisioning profile*, and so the
entitlements that require one — iCloud, App Groups, Push. This app needs none of those,
which is what §0 means by "switched on later without redesign": the architecture doesn't
have to change.

Switching it on is still work rather than a flag flip. It means adding an entitlements
file and auditing everything the app reaches for — the Application Support directory,
outbound HTTPS to GitHub and Linear, Keychain access — then confirming each still works
inside the container. That work is deferred, not free, which is why there is no
entitlements file yet.

## What M0 is, and is not

M0 is the shell: a menu bar item that opens an empty popover, built and signed by one
command. The popover deliberately shows a placeholder rather than a mock of design 2a —
a drawing with no data behind it invites design review of something that does not exist
yet.

The panel, its tokens and the row layout are M3. The data behind them is M2 (GitHub) and
M5 (Linear). The icon's four states are M4; the SF Symbol here is a stand-in.
