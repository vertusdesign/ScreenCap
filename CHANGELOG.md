# Changelog

All notable changes are recorded here. This project follows
[Semantic Versioning](https://semver.org/).

## [3.0.0] — 2026-08-17

### Added

- **ScreenCap Player module** with a native macOS playback window, recording-library sidebar,
  folder grouping, add-video/add-folder flows and playlist-only removal.
- **Synchronized Track Editor** with a composite audio track, raw system/microphone tracks,
  shared playhead, current/total time, waveform lanes and always-available trim handles.
- **Non-destructive edits** with mute/remove confirmation, undo/redo, unsaved-edit protection when
  switching recordings, save-copy and atomic replace-original export paths.
- **Privacy-first transcription** using Apple's on-device Speech Recognition path when available;
  transcription is on-demand by default and can be explicitly switched to idle-time automatic mode.
- **After-recording action**: Open in ScreenCap Player is available in Preferences and is the
  default for new installations when the player module is present.

### Compatibility

- Existing VLC/QuickTime after-recording actions remain available.
- Removing a video or folder from the Player library never removes the source files from disk.

## [2.2.0] — 2026-08-14

More reliable long recordings and a smoother opened-image editing workflow.

### Added and improved

- **Recording output reliability**: bounded writer backpressure, explicit overflow handling,
  safer QuickTime timestamp validation and final movie checks for long recordings. The recorder
  now rejects genuinely incomplete video instead of silently accepting it, while ignoring
  metadata-only boundary samples that AVFoundation exposes around a valid movie.
- **Opened-image canvas**: source images open at 100% scale, centre on screen when possible, and
  support panning with a trackpad gesture or mouse wheel from any annotation tool.
- **System scroll direction**: opened-image panning follows macOS's Natural scrolling setting.
- **Opened-image saving**: saving without confirmation prefers the source folder and adds the
  `_ScreenCap` suffix before the extension, with a Save Panel fallback when needed.
- **Canvas extension**: dragging an image edge outward expands the scrollable editing area and
  fills only the newly added area with the current primary colour.

### Compatibility

- The static screenshot workflow remains independent of the recorder.
- The macOS 14 screenshot and macOS 15 recording requirements remain unchanged.

## [2.1.0] — 2026-08-13

Text recognition and existing-image annotation, while preserving the stable 2.0 screenshot
and recording workflows.

### Added

- **Text recognition tool** as the second item in the annotation toolbar. It uses macOS
  VisionKit locally, highlights recognized text, supports selection, `Cmd+A` and copying,
  and leaves the image pixels unchanged.
- **Finder image opening** for image files through the standard Open With/context-menu flow.
  Opened images use the existing annotation and export pipeline and the source file is never
  overwritten automatically.

### Compatibility

- The current stable release remains available as `v2.0.0`; this release adds only the two
  image workflow features and keeps static screenshot and recording paths independent.
- The minimum macOS requirement remains 14.0. VisionKit image analysis is available on the
  supported macOS baseline; devices without image analysis support show an explanatory toast.

## [2.0.0] — 2026-08-12

Stable full-display screen recording for macOS 15+ while preserving the existing static
screenshot workflow.

### Added

- **Full-display recorder** with an instant current-display path and a ScreenCap display picker.
  The picker leaves the selected display visually clear, uses a recording-reticle cursor, and
  intercepts clicks across the transparent display surface so the underlying app is not activated.
- **Three audio tracks** in each recording: a composite track first for ordinary players, then
  independent system-audio and microphone tracks for editing.
- **Audio controls during recording** for system audio and microphone, with timeline-preserving
  silence instead of track gaps. These controls do not mute or reconfigure other applications.
- **Microphone processing** with automatic level adjustment, gentle compression, peak limiting and
  optional light RNNoise suppression.
- **Recording settings** for folder, filename template, save prompt, logical-size capture, H.264/
  HEVC selection, audio exclusions, RNNoise and after-recording application actions.
- **VLC handling** that reuses the existing VLC instance/playlist where possible and pauses the
  newly opened recording after the video window is ready.
- **Stability safeguards** including hardware encoder selection, silent-audio fallback, microphone
  route monitoring, disk-space checks, five-second movie fragments, recovery markers and bounded
  diagnostic logs.

### Changed

- The menu item **Start recording** is now **Start recording (current display)**. **Stop recording**
  remains unchanged.
- The release version is now 2.0.0 and the documentation describes the recorder as part of the
  stable product surface.

### Known limitations

Pause/resume, window/application/area recording, countdown, live audio meters, camera overlay,
preview/editing, HDR, click visualization, full crash-recovery UX, and broad long-duration,
Bluetooth, Intel and macOS 15 regression coverage remain future work.

## [1.1.0] — 2026-08-09

Polished stable release focused on the capture overlay, permission recovery and distribution
documentation.

### Highlights

- **Permission recovery** now separates macOS's native first-request dialog from the app's
  retry explanation, prevents duplicate prompts, and opens the exact Screen Recording pane
  from the status menu or fallback dialog.
- **Overlay controls** use system-style resize cursors, a clearer settings marker, and
  consistent tool-panel interactions including long-press and double-click toggling.
- **Redaction and editing** keep repeated blur/pixelate passes as visible layers while
  preserving annotations underneath, with improved brush previews and eraser geometry.
- **Distribution documentation** now includes a reusable Screen Recording permission
  specification for future macOS apps and for Windows/Linux platform adapters.

## [1.0.0] — 2026-08-09

First stable release. The capture flow, annotation tools, redaction, export, localization,
and universal Intel/Apple Silicon distribution are ready for regular use.

### Highlights

- **Cross-display Undo and Redo** keep the selected area when the capture flow moves between
  monitors.
- **Annotation editing** includes live text editing, object deletion with the eraser, and
  pixelation/blur that preserves annotations underneath.
- **Polished overlay controls** include square tool buttons, independent recent-color lists,
  a pixel loupe above the overlay chrome, and responsive tool settings.
- **Universal release packaging** produces a signed app bundle, disk image, and checksum for
  both Apple Silicon and Intel Macs.

## [0.9.1-alpha] — 2026-08-08

A bug-fix pass over the 0.9.0-alpha release, focused on the overlay's chrome and the text
tool.

### Fixed

- **Tooltips now actually appear.** AppKit's native tooltip window renders below the
  overlay's shielding window level, so it was drawing every time — just permanently hidden
  underneath the capture surface. Replaced with a small custom tooltip window one level
  above the overlay.
- **Square button highlights, for real this time.** The remaining cause of
  non-square/overlapping hover and selection highlights was a default focus ring AppKit
  draws on click, which bled a few points past each button's bounds and, with buttons
  packed 2 px apart in the tool strip, spilled into neighbours and past the panel's rounded
  corners. `focusRingType = .none` across every custom control fixes it.
- **Magnifier no longer lingers** on a display the pointer has left, and its
  coordinate/color readout no longer overflows the loupe's right edge.
- **A new selection now clears every other display's selection**, instead of leaving stale
  selections open on displays you're not looking at.
- **Text style changes apply instantly.** Changing the backdrop color, backdrop style,
  text color or font size while still typing used to only show up on the next keystroke,
  and a stray line was re-revealing the editor's raw (un-styled) text on top of the WYSIWYG
  preview, which read as "the color also applies to the text." Both are fixed: the live
  preview rebuilds on every style change, and the editor's own glyphs stay invisible as
  intended.
- **Text move handle shows a hand cursor** on hover, instead of whatever the tool underneath
  would normally show.
- **Toolbars stay hidden while you create, resize or move the selection**, instead of
  chasing the drag around the screen, and reappear once you let go.
- **Esc steps down to the move tool** before it closes the overlay, when a different tool
  was active; closes immediately if the move tool is already selected or nothing is
  selected. Double-clicking outside the selection (or with none) also closes it.
- **Eraser gained brush/rectangle/ellipse shapes**, matching redaction, with brush as the
  default for both.
- **Arrow tool** supports a double-headed variant, via ⌃-drag or a persisted choice in the
  style popover — along with the filled-shape and redaction-style alternates, which are now
  also reachable from the popover instead of only through ⌃.
- **Toolbar icons render crisp on non-Retina external displays**; they were reusing a
  bitmap cached at the built-in display's Retina scale.
- **Preferences → Capture** sizes to its actual content instead of clipping the "Reset
  capture settings" button, and its selector rows (shape/arrow/backdrop style) now sit above
  the sliders they configure rather than below.
- **Settings window**: recording a shortcut no longer fires the action it's about to
  replace; hotkey fields gained a clear button; the shortcuts hint and reset button moved
  above the divider; the Save-As panel and the app's own Capture settings both gained a
  PNG/JPEG format choice.
- Every toolbar and action-bar button now has a tooltip naming it and its shortcut, and the
  cursor turns into a plain arrow over the toolbars, action bar and style popover instead of
  the drawing crosshair.
- The overlay no longer shows a brief window-zoom pop-in animation when it first appears.

### Changed

- Full-screen capture's default shortcut is now ⌘⌥F4. It previously shared ⌘F5 with
  VoiceOver's screen-curtain toggle on some setups.
- Default filename template is now `Screenshot_{timestamp}`, and clicking one of the
  available tokens inserts it at the cursor instead of only appending it.
- All 24 interface languages carry every string introduced since 0.9.0-alpha; none of them
  were silently falling back to English.

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
- **Text backdrops**: a solid or translucent color behind the text, a drop shadow, or
  nothing, with the backdrop color chosen separately.
- **Color panel** with an 18-color palette, recently used colors, a hex field, an
  eyedropper that samples the frozen screenshot, and a route out to the system color panel.
- **Pixel loupe** showing the pixels around the cursor with their coordinates and color in
  hex and RGB. `C` with no selection copies the color under the cursor.
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
