# Disclaimer

## No warranty

ScreenCap is provided **as is**, without warranty of any kind. The full legal text is in
the [MIT Licence](LICENSE). Nobody is obliged to fix anything, support anything, or keep
anything working.

## Stable release, with documented boundaries

Version 2.2.0 is the current stable release. The capture, drawing, export and core full-display
recording paths work and have been tested by hand. The remaining intentional boundaries are listed in the
[README](README.md#known-limitations).

Do not use it where a failure would cost you something.

In particular: **check a redacted screenshot before you share it.** Pixelation and blur are
baked into the exported image, but while the overlay is still open the eraser can take a
redaction back off. The app cannot tell the difference between that and any other edit.

## What the app can see

To do its job the application holds Screen Recording permission, which is one of the most
powerful macOS grants — it is what lets any app read your display.
[PRIVACY.md](PRIVACY.md) describes exactly how it is used, and
[SECURITY.md](SECURITY.md) lists what the binary provably does not do. Since the source is
open, you are encouraged to verify that rather than take anyone's word for it.

If you are not comfortable granting that permission, do not install the application. There
is no version of it that works without it, because macOS provides no other way to read the
screen.

## Not notarized

Builds are not notarized by Apple, so macOS blocks the first launch and you have to allow
it explicitly. That is a genuine gap, not a formality: notarization is Apple's malware scan
of the shipped binary. Building from source avoids the question entirely.

## Relationship to Lightshot

ScreenCap is an independent implementation inspired by Lightshot's approach to screenshots.
It shares no code with Lightshot and is not affiliated with or endorsed by Skillbrains.
