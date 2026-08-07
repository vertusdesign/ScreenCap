# Changelog

All notable changes are recorded here. This project follows
[Semantic Versioning](https://semver.org/) once it reaches 1.0; until then the minor version
carries breaking changes.

## [0.9.0-alpha] — 2026-08-07

First public release.

### Added

- **Four capture modes**, each on a configurable global shortcut: area (⌘F2), repeat last
  area (⌘F3), window under the cursor (⌘F4) and full screen (⌘F5). The screen is frozen the
  instant the shortcut fires, so open menus and hover states stay put while you frame the
  shot.
- **Drawing tools**: pen, highlighter, line, arrow, rectangle, ellipse, redaction,
  numbered circles, text and an eraser, each on a single-key shortcut.
- **Redaction** with a choice of pixelation or blur, a rectangular, elliptical or free-brush
  region, and adjustable intensity.
- **An eraser that erases**, rather than deleting whole objects. Annotations are composited
  into a transparent raster layer above the screenshot and the eraser punches transparency
  into it, so part of a stroke can be taken away. Annotations stay vector data underneath,
  and the layer is re-flattened at the export scale on save.
- **Drawing modifiers**, combinable: ⇧ constrains to a square or 45°, ⌥ grows the shape from
  its centre, ⌃ switches to the tool's alternate — a filled shape, or the other redaction
  style. The active tool's icon changes while ⌃ is held.
- **Text backdrops**: a solid or translucent colour behind the text, a drop shadow, or
  nothing, with the backdrop colour chosen separately.
- **Colour panel** with an 18-colour palette, recently used colours, a hex field, an
  eyedropper that samples the frozen screenshot, and a route out to the system colour panel.
- **Pixel loupe** showing the pixels around the cursor with their coordinates and colour in
  hex and RGB. `C` with no selection copies the colour under the cursor.
- **Undo covering the selection**, not just the drawing: moving and resizing the frame are
  undoable steps. A run of arrow-key nudges collapses into one step.
- **Output**: clipboard as PNG and TIFF, PNG on disk under a configurable filename template,
  Save As, and print. ⇧-clicking Save, or ⇧⌘S, asks where to put the file.
- **24 interface languages** with English as the fallback for any missing string, switchable
  from the menu without a restart.
- **A URL scheme**, `screencap://`, so Shortcuts, Raycast, Automator or a shell script can
  trigger a capture when a shortcut is already taken by another app.
- **A headless self-test** (`--selftest`) that renders every annotation type, exports a PNG,
  and checks the geometry and shortcut round-trips. It is what CI runs.

### Notes on a few decisions

- **Shortcuts are matched on the physical key**, not the character it produces. Matching on
  the character breaks every shortcut on a Cyrillic or Greek layout, where `C` types `с`.
- **⌃-drag is routed from the right-mouse events.** macOS turns ⌃-click into a secondary
  click at the window-server level, so without that routing the ⌃ alternate would be
  unreachable with a mouse.
- **No permission prompt at launch.** `CGRequestScreenCaptureAccess` blocks the calling
  thread until its dialog is answered, and that dialog can appear behind other windows or on
  another display — leaving the app wedged and unable to open its own windows. The first
  capture asks instead, when the user is looking.
- **No preflight permission check before a capture.**
  `CGPreflightScreenCaptureAccess` reports false whenever the app's signature has changed
  since the grant, even though capture still works. Gating on it produced a permission
  dialog before every single capture.
- **Panels open on the display holding the pointer**, not on `NSScreen.main`. For a menu-bar
  app "main" is whichever display last had key focus, which is rarely the one being looked
  at.
