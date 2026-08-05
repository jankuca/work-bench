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

- the whole build is described in text a reviewer can actually read — `Package.swift` and
  a `Makefile` — rather than in a project file that turns every touch into merge noise;
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
a downloaded archive that propagated the attribute — `xattr -dr com.apple.quarantine
build/PRStackMonitor.app` clears it. That is a troubleshooting step for a bundle you just
built from a checkout you trust, and for nothing else: stripping quarantine off a
downloaded or unverified app removes exactly the check that exists to protect you.)

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

The one thing worth not mis-filing: **the App Sandbox itself needs no paid Apple
Developer account**, and it does contain the app for real. Certain entitlements are gated
on a provisioning profile, and which ones depends on both the capability and how the app
is distributed — that is Apple's documentation to answer, not this README's.

None of it arises yet, because this app claims no entitlements at all. That is what §0
means by "switched on later without redesign": the architecture doesn't have to change.

Switching it on would still be work rather than a flag flip — an entitlements file, then
confirming that the Application Support directory, outbound HTTPS to GitHub and Linear,
and Keychain access all still function inside the container. Deferred, not free, which is
why there is no entitlements file yet.

## What is here, and what is not

The panel is real as of M3: design 2a's tokens, rows, spine, sections, header and footer,
plus the all-clear and first-run/disconnected states. It renders live pull requests — the
popover polls GitHub once when it opens and once per press of the refresh control.

Almost none of *what* it shows is decided in this package. `PRStackCore`'s presentation
layer resolves every row down to a title, an emphasis tier, a semantic tone, a meta line
and a release track; `PanelUI` turns those into geometry and colour. That split is what
lets the wording and composition be tested in CI, on Linux, where none of this could
build.

Not here yet:

- **Sync** (M8). `PanelController` polls on open and on demand. There is no interval
  table, no sleep or battery awareness, no backoff.
- **Interactions and persistence** (M7). `Mark all read`, dismiss and `Clear all` work,
  but only in memory — quitting forgets them. The hovered-row keyboard actions and the
  Settings window are M7 too; `Settings` currently explains where the token is read from.
- **The icon's four states** (M4). The SF Symbol is still a stand-in, and opening the
  panel does not yet clear unread.
- **Project headings from Linear** (M5). Until then every row groups under `Other`,
  because nothing populates `linearIssues`.

## Running it against your own pull requests

`make run` picks up a token from `$PRSTACK_GITHUB_TOKEN`, then `$GITHUB_TOKEN`, then the
login keychain. With none of them the panel shows the connect prompt. To see the panel
against fixture data without a token at all, `make panel` prints the same presentation the
row view consumes.
