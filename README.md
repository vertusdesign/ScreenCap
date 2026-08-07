# ScreenCap

Freeze the screen, select an area, mark it up in place, then copy or save. A menu-bar
screenshot tool for macOS, built because [Lightshot](https://app.prntscr.com/) — the one
that did this well — is no longer maintained.

**Status: alpha (0.9.0).** Everything described below works and has been tested by hand.
Some rough edges remain — see [Known limitations](#known-limitations).

> ### ⚠️ macOS will block the first launch — this is expected
>
> ScreenCap is **not notarized by Apple** (notarization requires a paid Apple Developer
> account). On first launch macOS says *"Apple could not verify ScreenCap is free of
> malware"* and offers only **Done** and **Move to Bin**.
>
> **Press Done**, then open **System Settings → Privacy & Security**, scroll to
> **Security**, and press **Open Anyway** next to the ScreenCap line. That is it — once only.
>
> On macOS 15 and newer the old right-click → Open trick no longer works for unnotarized
> apps. If you prefer the terminal, `xattr -d com.apple.quarantine /Applications/ScreenCap.app`
> does the same thing. Building from source avoids the warning entirely, because nothing is
> downloaded and so nothing is quarantined.

Everything happens on your Mac. No accounts, no uploads, no network access at all.

- Four capture modes on global shortcuts: area, repeat last area, window under the cursor, full screen
- The screen freezes the moment you press, so menus and tooltips stay put while you aim
- Draw on top: pen, highlighter, line, arrow, rectangle, ellipse, redaction, numbering, text
- Redaction does pixelation or blur, in a rectangle, an ellipse or a free brush stroke
- An eraser that rubs out part of a stroke rather than deleting whole objects
- Pixel loupe with an eyedropper, and a colour panel with palette, recents, hex and a screen picker
- Copy to the clipboard, save as PNG, or print
- 24 interface languages
- No Dock icon, no background polling, no network access of any kind

## Install

Download the disk image from the [latest release](https://github.com/vertusdesign/ScreenCap/releases/latest),
open it and drag **ScreenCap.app** onto **Applications**.

One disk image covers both processor families: the app is a universal binary and runs
natively on Apple silicon and on Intel, no Rosetta involved.

**Then allow it past Gatekeeper — see the notice at the top of this page.** The app is not
notarized, so the first launch is blocked until you press **Open Anyway** in
**System Settings → Privacy & Security**. Once only.

If you prefer the terminal, this does the same thing by clearing the download quarantine
flag:

```bash
xattr -d com.apple.quarantine /Applications/ScreenCap.app
```

### Permission

The first time you take a screenshot macOS asks for one permission:

| Permission | Why it is needed |
|---|---|
| **Screen Recording** | To read the pixels of the screen you are capturing |

After granting it, **restart the app** — macOS does not apply a new permission to a process
that is already running.

macOS calls this permission "Screen Recording" for anything that reads the screen,
including a single still frame. ScreenCap takes one frame when you press the shortcut and
nothing else; it never streams, never records, and nothing leaves your machine. See
[PRIVACY.md](PRIVACY.md).

## Capture

| Action | Default shortcut |
|---|---|
| Capture area | ⌘F2 |
| Repeat last area | ⌘F3 |
| Capture window under cursor | ⌘F4 |
| Capture full screen | ⌘F5 |

All four are configurable in Settings, and any of them can be cleared.

The screen is captured the instant the shortcut fires and the still is what you then select
from. An open menu, a hover tooltip, a drag in progress — all of it stays exactly where it
was while you take your time framing the shot.

If another application already owns a shortcut, macOS gives it to that application and
ScreenCap's registration silently fails. Settings marks such a shortcut with a warning
triangle instead of leaving you guessing.

## Drawing

Pen, highlighter, line, arrow, rectangle, ellipse, redaction, numbered circles, text and an
eraser. Every tool has a single-key shortcut, shown in its tooltip.

| Key | Tool | | Key | Tool |
|---|---|---|---|---|
| `V` | Move / adjust selection | | `O` | Ellipse |
| `P` | Pen | | `B` | Redact |
| `H` | Highlighter | | `N` | Numbering |
| `L` | Line | | `T` | Text |
| `A` | Arrow | | `E` | Eraser |
| `R` | Rectangle | | | |

Shortcuts are matched on the **physical key**, not the character it produces, so they work
on Cyrillic, Greek and every other non-Latin layout.

### Modifiers

Held while drawing, and they combine:

| Modifier | Effect |
|---|---|
| `⇧` | Square or circle; for line and arrow, snap to 45° |
| `⌥` | Grow from the starting point as the centre |
| `⌃` | The tool's alternate: a filled shape, or the other redaction style |

While `⌃` is held the active tool's icon changes to show what will actually be drawn.

macOS turns ⌃-click into a secondary click at the window-server level, so a ⌃-drag arrives
as a right-mouse event. ScreenCap routes those back to the normal path; without that, the
alternate would be unreachable with a mouse.

### The eraser

Everything you draw is composited into one transparent raster layer above the screenshot,
and the eraser punches transparency into that layer. So it takes away *part* of a stroke,
the way a rubber does on tracing paper, instead of deleting whole objects.

Annotations stay vector data underneath — that is what undo and a crisp Retina export need
— and the layer is re-flattened at the export scale when you save.

Order is preserved: an erase stroke only affects what was drawn before it, so you can erase
and then draw again over the same spot.

### Actions

`⌘C` copy · `⌘S` save · `⇧⌘S` save as (or ⇧-click the save button) · `⌘P` print ·
`⌘Z` / `⇧⌘Z` undo and redo · `⌘A` select the whole screen · `↩` copy and close · `Esc`
cancel · arrow keys nudge the selection by 1 px, 10 px with `⇧` · `⌘↩` commits text.

Undo covers moving and resizing the selection as well as drawing. A run of arrow-key nudges
collapses into a single undo step.

## Known limitations

- **Not notarized**, so Gatekeeper blocks the first launch until you allow it in
  System Settings → Privacy & Security (see [Install](#install)).
- **A selection lives on one display.** You can capture any display, but a single selection
  cannot span two of them.
- **No scrolling capture**, no video, no OCR, no annotation of an existing image file.
- Redaction is applied to the exported pixels, which is what makes it safe — but the eraser
  can take a redaction back off while the overlay is open. Check the result before sharing.
- Right-to-left languages are translated but the layout is not mirrored.
- The app is alpha and has been tested by hand rather than by an automated UI suite. The
  rendering and export paths are covered by `--selftest`.

## Automation

If a shortcut you want is already taken, or you would rather trigger a capture from
Shortcuts, Raycast, Automator or a script, the app registers a URL scheme:

```bash
open "screencap://area"
```

Commands: `area`, `repeat`, `window`, `fullscreen`, `preferences`, `about`.

## Build from source

Requires macOS 14 or newer and a Swift toolchain (Xcode Command Line Tools are enough).

```bash
git clone https://github.com/vertusdesign/ScreenCap.git
```

```bash
cd ScreenCap && ./Scripts/create-signing-cert.sh && make install
```

`create-signing-cert.sh` is a one-time step. It puts a local, self-signed code-signing
certificate in your login keychain, and `make install` uses it. This matters more than it
sounds: macOS pins the Screen Recording grant to the code signature, and an ad-hoc signature
is only a hash of the binary — so without a certificate every rebuild invalidates the grant
and you re-approve the app each time. The certificate never leaves your machine and is not
trusted by anything; remove it in Keychain Access whenever you like.

`make install` then builds a universal binary, assembles the app bundle and copies it to
`/Applications`.

To produce the disk image and its checksum:

```bash
make dmg
```

Disk images are signed ad-hoc on purpose — a certificate only your machine holds is worth
nothing to anyone downloading the app. Both paths enable the hardened runtime.

During development the localised strings live outside the binary, so point the app at them:

```bash
swift build
SCREENCAP_STRINGS=Resources/l10n .build/debug/ScreenCap
```

Useful flags: `SCREENCAP_DEBUG=1` traces to stderr, `--capture area|repeat|window|fullscreen`
captures immediately after launch, `--window about|preferences` opens a panel.

The headless self-test renders every annotation type, exports a PNG, checks the geometry and
shortcut round-trips, and captures the screen if permission allows. It is what CI runs:

```bash
.build/debug/ScreenCap --selftest /tmp/screencap-check
```

## Documentation

| Document | Contents |
|---|---|
| [PRIVACY.md](PRIVACY.md) | What the app can see, and what it does with it (nothing leaves the machine) |
| [TERMS.md](TERMS.md) | Terms of use |
| [DISCLAIMER.md](DISCLAIMER.md) | No warranty, and what that means in practice |
| [SECURITY.md](SECURITY.md) | Threat model and how to report a vulnerability |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to propose changes |
| [CHANGELOG.md](CHANGELOG.md) | Release history |

## Relationship to Lightshot

ScreenCap is an independent implementation, written from scratch for macOS and inspired by
the way [Lightshot](https://app.prntscr.com/) by Skillbrains handled screenshots. It shares
no code with Lightshot, is not affiliated with or endorsed by its authors, and deliberately
leaves out its network features: no uploads to prnt.sc, no accounts, no sharing, no image
search.

## Licence

[MIT](LICENSE).
