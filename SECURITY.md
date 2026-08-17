# Security

## Reporting a vulnerability

Report privately through GitHub's
[security advisory form](https://github.com/vertusdesign/ScreenCap/security/advisories/new)
rather than a public issue. Please include the macOS version, the app version, and the steps
to reproduce.

This is a hobby project maintained without a schedule. Expect a first response within a
couple of weeks, and no guaranteed fix timeline.

## Why this project takes security seriously

ScreenCap holds Screen Recording permission. An attacker who subverted it would inherit the
ability to read everything on your display. That makes a few properties worth stating
explicitly, all of which can be checked against the source.

## What the app does not do

- **No networking.** No network framework is linked and no networking symbol appears in the
  binary. It cannot exfiltrate anything, including the screenshots it takes.
- **No code execution.** No `NSTask`, no `posix_spawn`, no `dlopen`.
- **No input monitoring.** No `CGEventTap`. The global shortcuts use Carbon's
  `RegisterEventHotKey`, which reports only the combinations it registered and needs no
  Input Monitoring permission — unlike an event tap, which would see every keystroke on the
  system.
- **No persistent capture.** Frames are taken on demand through `SCScreenshotManager`. No
  `SCStream` is opened, so there is no session that could keep reading the screen.
- **No file access beyond what you point it at.** Writes go to the save folder you chose or
  the path you pick in the save panel. Nothing is read from disk except the app's own
  resources.

Verify it yourself against a build:

```bash
otool -L "/Applications/ScreenCap 3.app/Contents/MacOS/ScreenCap"        # linked frameworks
nm -u "/Applications/ScreenCap 3.app/Contents/MacOS/ScreenCap" | sort    # undefined symbols
```

## Hardened runtime and signing

Release builds enable the hardened runtime. Builds made without a local signing certificate
fall back to ad-hoc signing and still enable it — without the hardened runtime, library
validation is off, and a local process could inject a dylib and inherit the app's Screen
Recording grant.

The app is **not notarized**, because notarization requires a paid Apple Developer account.
That is a real gap: notarization is Apple's malware scan of the shipped binary, and without
it you are trusting the source and the build. Building from source is the way to remove that
trust requirement, and it is one command.

The current direct-download targets are also not App Sandbox-enabled. That is intentional for
the present local/DMG workflow, but it means these exact entitlement sets are not yet App Store
submission targets. Before distribution through the Mac App Store, security-scoped bookmark/file
flows and the Screen Recording, microphone and Apple Events capabilities must be revalidated
under a sandboxed target. Speech recognition belongs only to the private Pro target.

## The URL scheme

The app registers `screencap://` so it can be triggered from Shortcuts, Raycast or a script.
Anything on your Mac that can open a URL can therefore start a capture.

What that gets an attacker is limited by design: the scheme accepts a fixed set of commands
with no parameters, cannot specify a region, cannot pick a destination, and cannot cause a
capture to be saved or copied without a person driving the overlay. A capture opens the
full-screen overlay, which is unmissable. There is no headless path.

## Threat model

In scope: anything that would let the app read the screen when the user did not ask, write
outside the chosen folder, execute code, or reach the network.

Out of scope: an attacker who already has code execution as your user, or admin on the
machine. At that point they can grant themselves Screen Recording directly and do not need
this app.
