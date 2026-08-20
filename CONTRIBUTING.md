# Contributing

Bug reports, ideas and patches are all welcome. This is a small project maintained in spare
time, so please be patient with response times.

## Reporting a bug

Include:

- macOS version and Mac model
- app version (menu → About ScreenCap)
- interface language, and your **keyboard layout** if a shortcut misbehaved
- how many displays you have, and their scale factors if they differ
- what you expected and what happened

Overlay bugs are often specific to the display arrangement and to which display the pointer
was on. Mention both.

If a shortcut does nothing, check Settings first: a shortcut already owned by another app is
marked with a warning triangle, because macOS gives it to whoever registered first.
Carbon registrations target ScreenCap's application event queue, so screenshot/recording
shortcuts continue to fire while the status-item menu, a popover or a context menu is being
tracked. A local AppKit monitor is retained as a narrow fallback for ordinary key events while
the app owns keyboard focus; Carbon remains the global registration path when another app is
focused.

## Proposing a change

Open an issue before a large pull request, so the design can be agreed before you spend the
time. Small fixes can go straight to a pull request.

Two things that will be asked of any change to the drawing code:

- **It must survive export.** The overlay and the saved PNG go through the same renderer on
  purpose. A change that looks right on screen but not in the file is a bug, and the reverse
  is worse.
- **It must be undoable.** Anything that mutates the annotation list or the selection pushes
  a history state.

## Development

The repository's current implementation is macOS-only. Read
[ARCHITECTURE.md](ARCHITECTURE.md) before changing session, geometry, rendering or output
code, and [PORTING.md](PORTING.md) before designing a Windows/Linux implementation.

Prerequisites for the macOS target are macOS 14 or newer, Swift 6 and the usual Apple
developer command-line tools. There are no third-party Swift package dependencies. From a
clean checkout:

```bash
make debug BUILD_FLAVOR=base
SCREENCAP_STRINGS=Resources/l10n .build/base/debug/ScreenCap
```

The localised strings live outside the binary, so a plain `swift build` run needs
`SCREENCAP_STRINGS` pointed at them, otherwise the UI shows raw keys.

Useful while debugging:

| Flag | Effect |
|---|---|
| `SCREENCAP_DEBUG=1` | Traces overlay lifecycle and input to stderr |
| `--capture area\|repeat\|window\|fullscreen` | Captures immediately after launch |
| `--window about\|preferences` | Opens a panel after launch |
| `--selftest <dir>` | Runs the headless render and export checks |

Before opening a pull request:

```bash
make debug BUILD_FLAVOR=base 2>&1 | tee /tmp/screencap-build.log
.build/base/debug/ScreenCap --selftest /tmp/screencap-check
```

Swift 6 concurrency diagnostics and deprecated AVFoundation APIs are treated as defects in
application code: review and fix them before merging. Vendored RNNoise is allowed to contain
upstream performance advisories, but those must be documented and must not hide correctness
warnings. Translation CI treats English as the source catalog and allows a locale to omit a
key temporarily because runtime lookup falls back to English.

For a release-shaped local check, also run `make dmg BUILD_FLAVOR=base VERSION=3.0.0 CHANNEL=` and
verify the result with `lipo -archs "dist/ScreenCap 3.app/Contents/MacOS/ScreenCap"`, the version
and build keys in `dist/ScreenCap 3.app/Contents/Info.plist`, and
`(cd dist && shasum -a 256 -c ScreenCap-3-3.0.0.dmg.sha256)`. The CI workflow is the canonical
copy of these checks.

Every packaged app must receive a new monotonically increasing `CFBundleVersion` (`BUILD`). Local
Makefile packaging allocates it automatically through `Scripts/next-build-number.sh`, and About
must show the same value as `(build N)`. CI or a reproducible build may pass an explicit unique
`BUILD`; reusing a build number for a different artifact is not allowed.

The public checkout deliberately contains only ScreenCap 3. To build the private Pro flavor,
place its private source directory at `../ScreenCap-Pro-Private` (or pass `PRIVATE_DIR` explicitly):

```bash
make app BUILD_FLAVOR=pro PRIVATE_DIR=../ScreenCap-Pro-Private VERSION=3.0.0
open "dist/ScreenCap 3 Pro.app"
```

The sibling directory is not tracked by this public repository. It is a required, separate
private Git worktree: initialise it with its own private remote, commit Pro changes there, and
sync that repository independently. Build targets read it and stage only a temporary ignored
copy under `Sources/ScreenCap/Player`; they never delete or commit the sibling. A missing
directory or a directory without Git history is a hard Pro-build error, not a fallback to a
Player-less binary.

### Private Pro source is the only editable source of Player code

`Sources/ScreenCap/Player` is a generated staging directory, not a development checkout. A Pro
build copies the committed contents of `ScreenCap-Pro-Private/Player` into it; a base build clears
that staging copy intentionally. Therefore:

- make and review all Pro Player changes in the private worktree;
- commit the private change before running a Pro build or handing it off;
- never use the staged copy as the recovery source for an uncommitted change;
- after a base build, verify the private worktree rather than assuming Player files were lost;
- keep the public worktree free of Pro source, including generated staging files and artifacts.

If a change appears only under `Sources/ScreenCap/Player`, stop and move it to the private
worktree before continuing. This invariant prevents a routine public build from removing the only
copy of Pro work.

Use these checks from the public checkout:

```bash
make private-status PRIVATE_DIR=../ScreenCap-Pro-Private
git -C ../ScreenCap-Pro-Private fetch --prune origin
make private-sync-check PRIVATE_DIR=../ScreenCap-Pro-Private
```

`private-sync-check` requires a clean private worktree, an `origin` remote, an upstream branch,
and zero ahead/behind commits after the last fetch. It does not push or pull automatically;
review and run those operations in the private repository deliberately. `PRIVATE_FETCH=1` may
be used when a fetch is explicitly wanted. Google Drive is only storage here, not the canonical
Git synchronization mechanism; do not edit the same private worktree concurrently on multiple
machines through cloud sync.

Pro uses `com.vertusdesign.ScreenCap.Pro3` and `screencap-pro3://`, while the base product
uses the stable `com.vertusdesign.ScreenCap` and `screencap://`. Both flavors may be installed
side by side; `make install BUILD_FLAVOR=pro` installs `/Applications/ScreenCap 3 Pro.app` and
does not remove the base app.

For a build that keeps its Screen Recording grant across rebuilds, sign it with a local
certificate — `make install` picks one up from your keychain automatically if it is there.
Without it macOS invalidates the grant on every rebuild.

## Translations

Strings live in `Resources/l10n/<lang>.lproj/Localizable.strings`, one file per language,
all sharing the key order in `Scripts/l10n_keys.json`.

To correct an existing translation, edit its file. Nothing else is needed — English fills in
for any key a translation is missing, so a partial file degrades gracefully rather than
showing raw keys.

To add a language, add its `.lproj` folder, add the code to `AppLanguage` in
`Sources/ScreenCap/Support/L10n.swift` with its endonym, and list it in
`CFBundleLocalizations` in `Resources/Info.plist`.

Corrections from native speakers are especially welcome — the existing set was not reviewed
by one for every language.

## Release checklist

1. Update the version/date in `CHANGELOG.md`, user-facing documentation and legal documents
   when their stated version or update date changes.
2. Run the debug build, self-test and translation catalog check from `.github/workflows/ci.yml`;
   fail the review for any new Swift 6 concurrency or AVFoundation deprecation warning.
3. If the change touches Pro, commit and sync `ScreenCap-Pro-Private` separately, then run
   `make private-sync-check PRIVATE_DIR=../ScreenCap-Pro-Private`. Never add Pro files to the
   public repository or use a public remote for the private checkout.
4. Build a local universal DMG and verify architecture, `CFBundleShortVersionString`, empty
   stable channel, and checksum.
5. Commit the complete release scope on `main`, create an annotated `v<version>` tag, and push
   the commit and tag. `.github/workflows/release.yml` builds the release DMG on `macos-15`,
   runs the self-test, uploads the artifact and creates the GitHub Release from
   `.github/RELEASE_NOTES.md`.
6. Open the published release and verify that it is not marked as a draft/prerelease and that
   both the DMG and `.sha256` assets are present.

## Code style

Match what is there. The house habits, briefly: comments explain *why* rather than what,
platform quirks get a sentence saying which quirk and what it costs, and names are spelled
out rather than abbreviated.

## Licence

Contributions are accepted under the [MIT Licence](LICENSE), the same terms as the rest of
the project.
