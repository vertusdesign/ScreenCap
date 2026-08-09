Freeze the screen, select an area, mark it up in place, then copy or save. Universal binary — runs natively on Apple silicon and Intel.

This is the first stable release of ScreenCap. It brings the complete capture and annotation
workflow together with cross-display Undo/Redo, live text editing, object deletion, safe
pixelation and blur, a polished overlay, 24 interface languages, and a universal Intel/Apple
Silicon build. See the [changelog](https://github.com/vertusdesign/ScreenCap/blob/main/CHANGELOG.md#100--2026-08-09) for the full list.

### What it does

- **Four capture modes** on configurable global shortcuts: area (⌘F2), repeat last area (⌘F3), window under the cursor (⌘F4), full screen (⌘⌥F4).
- **The screen freezes** the instant the shortcut fires, so an open menu or a hover tooltip stays put while you frame the shot.
- **Drawing tools**: pen, highlighter, line, arrow, rectangle, ellipse, redaction, numbered circles, text and an eraser, each on a single-key shortcut.
- **Redaction** with pixelation or blur, in a rectangle, an ellipse or a free brush stroke, with adjustable intensity.
- **An eraser that erases.** Annotations are composited into a transparent raster layer above the screenshot and the eraser punches transparency into it, so it takes away part of a stroke instead of deleting whole objects. The vector data stays underneath, and the layer is re-flattened at the export scale on save.
- **Modifiers while drawing**, combinable: `⇧` square or 45°, `⌥` grow from the centre, `⌃` the tool's alternate — a filled shape, or the other redaction style. The tool's icon changes while `⌃` is held.
- **Color panel** with palette, recently used colors, a hex field, an eyedropper that samples the frozen screenshot, and a route out to the system color panel.
- **Pixel loupe** with coordinates and the color under the cursor in hex and RGB.
- **Undo covers the selection**, not just the drawing — moving and resizing the frame are undoable steps.
- **24 interface languages**, switchable from the menu without a restart, with English filling in for anything untranslated.
- **A `screencap://` URL scheme** for Shortcuts, Raycast, Automator or a script, for when the shortcut you want is already taken.

Shortcuts are matched on the physical key rather than the character it produces, so they work on Cyrillic, Greek and every other non-Latin layout.

### Pay attention to the following before the installation

> #### ⚠️ macOS will block the first launch — this is expected
>
> This build is **not notarized by Apple** (that needs a paid Apple Developer account), so
> macOS says *"Apple could not verify ScreenCap is free of malware"* and offers only **Done**
> and **Move to Bin**.
>
> **Press Done**, then open **System Settings → Privacy & Security**, scroll to **Security**,
> and press **Open Anyway** next to the ScreenCap line. Once only.
>
> On macOS 15 and newer the old right-click → Open trick no longer works. From the terminal,
> `xattr -d com.apple.quarantine /Applications/ScreenCap.app` does the same. Building from
> source avoids the warning entirely.

### Install

Download the disk image, open it, drag **ScreenCap.app** onto **Applications**.

**Then allow it past Gatekeeper — see the notice above.**

On the first capture, macOS asks for **Screen Recording**. It is the permission macOS requires for anything that reads the screen, including a single still frame. Grant it in System Settings → Privacy & Security, then **restart the app** — macOS does not apply a new permission to a running process.

Nothing leaves your machine: the app contains no networking code at all. See [PRIVACY.md](https://github.com/vertusdesign/ScreenCap/blob/main/PRIVACY.md).

### Verify the download

```
shasum -a 256 -c ScreenCap-1.0.0.dmg.sha256
```

### Requirements

macOS 14 or newer. Apple silicon or Intel.

**Full changelog:** https://github.com/vertusdesign/ScreenCap/blob/main/CHANGELOG.md
