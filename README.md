# ScreenCap

Freeze the screen, select an area, mark it up in place, capture stills, or record the
display with system audio and microphone tracks. A menu-bar screenshot and screen
recorder for macOS, built because [Lightshot](https://app.prntscr.com/) — the one that did
this well — is no longer maintained.

**Version 3.0.0 — recording, playback and privacy-first transcription.** ScreenCap includes
a native macOS 15+ recorder, a local recording Player with synchronized track editing, and
on-device speech recognition when the selected language is supported by macOS.
See [Known limitations](#known-limitations) for the remaining intentional boundaries.

The shipped implementation is macOS-only. The product contract and the planned Windows/Linux
adaptation are documented in [ARCHITECTURE.md](ARCHITECTURE.md) and
[PORTING.md](PORTING.md); those ports must account for each platform's capture, compositor,
permission and global-hotkey rules rather than assuming macOS APIs exist everywhere.

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
- Recognize text as a dedicated second toolbar tool, select it with Live Text and copy it
- Open existing images from Finder and annotate them with the same tools
- Redaction does pixelation or blur, in a rectangle, an ellipse or a free brush stroke
- An eraser that rubs out part of a stroke rather than deleting whole objects
- Pixel loupe with an eyedropper, and a color panel with palette, recents, hex and a screen picker
- Copy to the clipboard, save as PNG, or print
- Screen recording on macOS 15+: full-display video with separate system-audio and microphone tracks
- ScreenCap Player: playlist folders, synchronized video/audio tracks, trim, per-track gain/mute/remove,
  composite rebuild and safe copy/replace export
- On-demand transcription through Apple's on-device Speech Recognition path, with an optional automatic mode
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

On the first launch, if access is missing, macOS asks for one permission:

| Permission | Why it is needed |
|---|---|
| **Screen Recording** | To read the pixels of the screen you are capturing |
| **Microphone** | To add your voice as a separate recording track |

After granting it, **restart the app** if macOS does not apply the change to the already
running process. If the native prompt has already been answered and access is still missing,
ScreenCap shows its own explanation with a button to open the exact Screen Recording settings
page. The same retry flow is available from the first menu item in the status menu. The
reusable, platform-adapter-friendly algorithm is specified in
[specs/screen-recording-permissions.md](specs/screen-recording-permissions.md).

macOS calls this permission "Screen Recording" for anything that reads the screen,
including a single still frame. ScreenCap takes one frame when you press the shortcut; the
recorder is a separate macOS 15+ feature, and nothing leaves your machine. See
[PRIVACY.md](PRIVACY.md).

## Capture

| Action | Default shortcut |
|---|---|
| Capture area | ⌘F2 |
| Repeat last area | ⌘F3 |
| Capture window under cursor | ⌘F4 |
| Capture full screen | ⌘⌥F4 |

All four are configurable in Settings, and any of them can be cleared.

The screen is captured the instant the shortcut fires and the still is what you then select
from. An open menu, a hover tooltip, a drag in progress — all of it stays exactly where it
was while you take your time framing the shot.

If another application already owns a shortcut, macOS gives it to that application and
ScreenCap's registration silently fails. Settings marks such a shortcut with a warning
triangle instead of leaving you guessing.

## Recording

On macOS 15 and newer, **Start recording (current display)** immediately records the full
display under the pointer; selecting it again stops the recording. **Choose display and record**
opens a lightweight ScreenCap overlay: the display under the pointer stays clear, other displays
are dimmed, and a transparent interaction layer prevents clicks from reaching the application
underneath. The bottom-center controls let you cancel or start recording, and the start button
is focused by default. Both actions are global and fully configurable in Settings. Recording
settings have their own tab with a destination folder, filename template, save prompt,
optional system-audio/microphone exclusion, logical-size capture, codec choice, gentle RNNoise
noise suppression, and an after-recording action. The file is saved as a `.mov` and contains
independent system-audio and microphone tracks plus a composite audio track first in the
container for ordinary players. System audio is captured by ScreenCaptureKit, so changing
headphones, speakers, docks, or output devices does not require a virtual audio driver or
change the screenshot path.

The recorder uses the system-default input selected when the recording starts. Microphone and
system-audio toggles are available in the menu bar while recording; they only mute ScreenCap's
own tracks and do not mute or reconfigure Teams, Zoom, Meet, or another calling app. Muting
keeps silent samples on the original timeline, so re-enabling a track cannot collapse the gap.
ScreenCap also applies automatic level adjustment, gentle compression, peak limiting and optional
light RNNoise suppression to its microphone track after capture. This raises a quiet microphone
without changing the system input level or the microphone signal received by another app.
The two persistent “do not record” checkboxes in Recording settings and the recording menu are
off by default and apply to the next recording. The default recording shortcut is **⌥⌘F2**;
the display-picker shortcut defaults to **⌥⇧⌘F2**, the microphone toggle to **⌥⇧⌘M**, and the
system-audio toggle to **⌥⇧⌘S**. All are configurable. The equivalent URL and CLI commands are:

```bash
open "screencap://record"
.build/debug/ScreenCap --capture record
```

The in-app HUD remains the source of truth while a recording is being finalized and continues
to work when notifications are disabled. At the terminal state, ScreenCap may also show a
local system notification: warnings, recovered recordings and failures are always eligible;
ordinary success is notified only when ScreenCap is inactive and no after-recording action has
already opened a destination. The notification permission is requested lazily, with no sound,
badge or network service. Its actions can open the recording in the Player or reveal it in Finder.

## Player

Open **ScreenCap Pro 3 → Open Player**. The Player is a separate regular macOS window while it
is visible, so it appears in the menu bar, Cmd-Tab and Mission Control. It is not opened just
because the app launched. The initial **After recording** setting is unconfigured. After the
first successful recording, ScreenCap asks what to do with the file; the chosen action is then
remembered. Choosing **Later** or closing the dialog leaves it unconfigured and asks again after
the next successful recording. This can also be changed in Recording settings.

Add individual movies or folders with the **+** button. Folder groups are recursive and are
stored as a playlist, not as a second copy of the files. Removing a video or folder removes
only the playlist entry; it never deletes the source. If the selected recording has unsaved
trim/audio edits, removal asks for confirmation before clearing the draft.

The Track Editor is hidden by default. The timeline button in the bottom navigation opens it
and replaces the ordinary playback scrubber. Video thumbnails, waveform lanes, one shared
playhead and current/total time stay synchronized. Audio lanes support independent gain,
mute and confirmed removal, including removing the final audio stream. **Rebuild Composite**
renders a new composite from the raw tracks (for example, after raising a quiet microphone)
without modifying the original until export.

Trim and audio changes are non-destructive drafts with undo/redo. Switching recordings keeps
the draft open until the user saves a copy, discards it, or cancels. **Replace original** uses
an atomic staged export; **Save edited copy** keeps the source untouched. Failed or cancelled
exports leave the draft intact.

### Transcription

Transcription is **On demand** by default. The button requests Speech Recognition permission
only when used; Automatic mode starts after a recording is opened and can be disabled in the
Player. The implementation requires Apple's on-device recognizer and never falls back to a
network service. Unsupported languages, unavailable recognizers, denied permission, videos
without audio, cancellation and disappeared files are shown as explicit errors rather than
silently uploading or losing the request. The transcript panel can be opened in the Player
window above the video while playback continues.

## Opened images

Images opened from Finder use the same annotation editor without changing the source file.
They open at 100% scale and are centred when possible; large images can be panned with a
trackpad gesture or mouse wheel from any tool, with the movement following macOS's Natural
scrolling setting. Dragging an image edge outward extends the editable canvas and fills only
the new area with the current primary colour. With confirmation disabled, saving writes next
to the source using a `_ScreenCap` suffix; if that folder is not writable, ScreenCap opens a
save panel instead.

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
- **No scrolling capture**, recorder microphone source picker, pause/resume, countdown, camera
  overlay, preview/editing window or HDR capture. Recording is currently one full display at a
  time and available on macOS 15+. Click visualization is supported and can be enabled both in
  Recording settings and in the display picker.
- The Player currently exports QuickTime `.mov` edits. It does not yet offer a separate
  transcript DOCX/RTF/PDF exporter or server-backed translation; transcript text remains local.
  Automatic transcription depends on Apple's on-device language model being available on that Mac.
- **Audio-device recovery and performance validation remain platform-dependent.** The recorder
  falls back to video/system audio when a microphone is unavailable, monitors input-route
  changes, keeps a bounded local diagnostic log, validates the finished movie, and stops safely
  when disk space is low. Crash-safe partial files, PID/boot-aware recovery markers, known-folder
  rescans, passthrough container repair, and graceful display/sleep/session/volume interruption
  handling are implemented. Finalization keeps a playable raw, repaired or recovered movie when
  optional audio processing or strict validation fails, reports the degraded result as “saved with
  warning” or “recovered”, and continues the configured after-recording action with the actual
  playable path. Recovery is local-only; it does not upload diagnostics and its dialog has Open,
  Show in Finder and Discard, not Try Again.
- Redaction is applied to the exported pixels, which is what makes it safe — but the eraser
  can take a redaction back off while the overlay is open. Check the result before sharing.
- Right-to-left languages are translated but the layout is not mirrored.
- The app has been tested by hand rather than by an automated UI suite. The rendering and
  export paths are covered by `--selftest`.

## Future work after 3.0

The following features remain intentionally out of scope for the current stable release and
should be considered only after 3.0:

- **Selection across multiple displays.** A single selection should be able to span
  displays, with the overlay and export composing the relevant parts of each screen.
- **Transcript export and translation.** Add explicit local export formats and an opt-in
  provider architecture only if a future release can preserve the current no-network default.
- **Player performance and format coverage.** Move large-folder enumeration and thumbnail
  generation off the main actor and expand the export matrix beyond QuickTime `.mov`.

## Automation

If a shortcut you want is already taken, or you would rather trigger a capture from
Shortcuts, Raycast, Automator or a script, the app registers a URL scheme:

```bash
open "screencap://area"
```

Commands: `area`, `repeat`, `window`, `fullscreen`, `record`, `preferences`, `about`.

## Build from source

The screenshot implementation requires macOS 14 or newer; the recorder requires macOS 15 or
newer. The project uses the Swift 6 language mode and an Xcode toolchain that can emit both
architectures. Xcode
Command Line Tools are enough for a debug build; the universal Intel/Apple Silicon build also
needs an Xcode toolchain that can emit both architectures. `make dmg` additionally needs the
macOS `hdiutil` and `codesign` tools. No third-party Swift package dependencies are used.

### Clean checkout

```bash
git clone https://github.com/vertusdesign/ScreenCap.git
cd ScreenCap
swift --version
swift build
SCREENCAP_STRINGS=Resources/l10n .build/debug/ScreenCap --selftest /tmp/screencap-check
```

The self-test is the first required check on another machine. It does not need an interactive
capture session; it renders the annotation/export paths and reports any screen-capture checks
that the current permission allows. A normal UI debug run is:

```bash
SCREENCAP_STRINGS=Resources/l10n .build/debug/ScreenCap
```

### App, install and distribution builds

```bash
make debug       # swift build
make app         # release .app, native for arm64 + x86_64
make run         # build the app and launch dist/ScreenCap.app
make install     # build and copy to /Applications
make dmg         # DMG + SHA-256 file in dist/
```

`make app` uses the default `VERSION`, `CHANNEL` and `BUILD` values from the Makefile. For a
specific stable release, pass them explicitly, for example:

```bash
make dmg VERSION=3.0.0 CHANNEL= BUILD=1
```

For a side-by-side permission/upgrade QA build, use the separate local identity:

```bash
make app BUILD_FLAVOR=parallel VERSION=3.0.0 BUILD=qa
# dist/ScreenCap-Pro3-QA.app — do not copy this flavor to /Applications
```

The production flavor keeps `com.vertusdesign.ScreenCap` and the `screencap://` scheme so a
3.0.0 App Store update remains the same macOS app and can continue using the existing v2
Screen Recording grant. The parallel flavor uses `com.vertusdesign.ScreenCap.Pro3QA` and
`screencap-pro3://`, so macOS presents it as a separate TCC identity. Build it for QA only;
the Makefile refuses `make install BUILD_FLAVOR=parallel`.

The distribution DMG is intentionally ad-hoc signed because a local certificate is not useful
to another machine. Gatekeeper instructions for downloaded builds are at the top of this
README. For local development, `./Scripts/create-signing-cert.sh && make install` creates a
self-signed certificate so macOS can keep the Screen Recording grant across rebuilds; this is
optional and should not be used as a release identity.

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

During development the localised strings live outside the binary, so point the plain SwiftPM
binary at them with `SCREENCAP_STRINGS=Resources/l10n`. The assembled `.app` copies the
localizations into its resource bundle and does not need that environment variable.

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
| [ARCHITECTURE.md](ARCHITECTURE.md) | Product contract, runtime layers, state, coordinates, rendering and testing invariants |
| [PORTING.md](PORTING.md) | Windows/Linux platform interfaces, capability matrix and acceptance scenarios |
| [specs/screen-recording-permissions.md](specs/screen-recording-permissions.md) | Reusable macOS Screen Recording permission algorithm and test matrix |

## Relationship to Lightshot

ScreenCap is an independent implementation, written from scratch for macOS and inspired by
the way [Lightshot](https://app.prntscr.com/) by Skillbrains handled screenshots. It shares
no code with Lightshot, is not affiliated with or endorsed by its authors, and deliberately
leaves out its network features: no uploads to prnt.sc, no accounts, no sharing, no image
search.

## Licence

[MIT](LICENSE).
