# Privacy Policy

**Last updated: 9 August 2026. Applies to ScreenCap 1.1.0.**

ScreenCap collects nothing, stores nothing about you, and sends nothing anywhere. This
document exists because the app requests a powerful permission, and you deserve a precise
account of what it does with it.

## The short version

- No analytics, no telemetry, no crash reporting, no automatic update checks, no accounts.
- The app contains **no networking code at all** — it cannot send data even in principle.
- Screenshots are held in memory while you edit them. They reach the disk only in the
  folder you chose, only when you press Save, and reach the clipboard only when you press
  Copy.

## The permission and what it is used for

### Screen Recording

macOS requires this permission for anything that reads the screen, including a single still
frame. ScreenCap uses it only to:

- take one still of each display at the instant you press a capture shortcut;
- list the on-screen windows, so "capture window under cursor" can highlight one and know
  its bounds.

The still is what you then select from and draw on. There is no continuous stream, no
recording, and no capture that you did not trigger — the app is idle between shortcut
presses and does not hold a capture session open.

macOS shows its own indicator while any app reads the screen. Seeing it for the moment a
capture is taken is expected; seeing it at any other time is not, and would be a bug worth
reporting.

## What leaves your Mac

Nothing, with two exceptions you trigger deliberately:

- **Files you save.** PNGs go to the folder set in Settings, or wherever you point the save
  panel. What you then do with those files is up to you.
- **Links you click.** The About window opens the project pages on github.com or the developer
  support page on patreon.com, and "Check for Updates…" opens github.com, all in your default
  browser. The app hands the URL to the system and stops there — it does not fetch anything,
  so those sites see your browser, not this app.

"Check for Updates…" therefore checks nothing. It opens the releases page and lets you
compare the version yourself. An in-app updater would need networking code, and this app
deliberately has none.

## What is stored on your Mac

User defaults under `com.vertusdesign.ScreenCap`: your shortcuts, save folder, filename
template, interface language, and the tool settings you last used, including the recently
used colors. Plain preferences, no content, no history of what you captured.

Removing the app and running `defaults delete com.vertusdesign.ScreenCap` removes all of it.

## Redaction

The redaction tool rasterises the pixelation or blur into the exported image. The original
pixels underneath are not carried into the saved PNG or the clipboard copy — the export is
flattened, not a layered document with a hideable mask.

One caveat while the overlay is still open: the eraser can take a redaction back off,
because the drawing layer stays editable until you copy or save. Once exported, the
redaction is final. Check what you are about to share before you share it.

## Third parties

There are none. No SDKs, no frameworks beyond Apple's own, no bundled dependencies.

## Changes

Material changes to this policy will be noted in [CHANGELOG.md](CHANGELOG.md) and dated at
the top of this file.

## Contact

Questions about privacy: open an issue at
<https://github.com/vertusdesign/ScreenCap/issues>. For anything security-sensitive, use
the process in [SECURITY.md](SECURITY.md) instead.
