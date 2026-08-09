# Windows and Linux porting guide

This is a design guide for a future native Windows or Linux implementation. It is not a
claim that those ports already exist. The macOS app remains the reference implementation for
product behaviour; this document explains what must be preserved and what must be replaced.

## Porting principles

1. Preserve the capture-session, annotation, rendering, history and output contracts from
   [ARCHITECTURE.md](ARCHITECTURE.md).
2. Replace operating-system services behind narrow interfaces. Do not emulate AppKit concepts
   such as `NSWindow`, `NSScreen`, `NSPasteboard` or Carbon key codes in shared code.
3. Treat platform capabilities as runtime data. In particular, Wayland does not promise the
   global window enumeration, global hotkeys, or arbitrary always-on-top interactive overlays
   that this macOS version uses.
4. Prefer a reduced, honest feature set over a fake implementation that violates the desktop's
   security model. The UI should explain an unavailable capability and offer the supported path.
5. Keep pixel and logical coordinate units explicit. Never pass an unlabelled `CGRect`-like
   value across a platform boundary.

## Recommended target decomposition

The existing Swift target can remain the macOS product, but a cross-platform effort should
extract a platform-neutral core with these concepts:

```text
core/
  geometry       display rectangles, scale, transforms, pixel alignment
  model          tools, styles, annotations, settings schema, output actions
  session        capture state machine, selection rules, history and undo/redo
  render         annotation compositing, obfuscation, erasing, export pixels
  tests          golden images and platform-independent acceptance cases

platform/<os>/
  capture        display snapshots and window enumeration
  overlay        input, top-level windows, shielding and focus
  hotkeys        global shortcut registration and conflict reporting
  clipboard      PNG/TIFF or equivalent image/text formats
  dialogs        save/open/preferences/about/system color picker
  settings       versioned user-data storage
  print          optional native print path
  packaging      executable, icons, signing and installer
```

The core may be implemented in portable C++, Rust, or another language shared by all three
targets. A native UI is still recommended per platform: AppKit, WinUI/WPF/Win32, and Qt/GTK
or another Linux toolkit each have different window, accessibility and compositor rules.

## Required platform interfaces

These interfaces describe behaviour, not a mandatory programming language:

| Interface | Required operation | Failure/capability result |
|---|---|---|
| `DisplayProvider` | Enumerate displays with stable ID, global logical rect, pixel size, scale, rotation and work area. | Report display changes; never silently mix stale snapshots. |
| `CaptureProvider` | Capture one immutable pixel image per display; capture the on-screen window list when Window mode starts. | Return permission denied, unavailable, or capture failed separately. |
| `OverlayHost` | Create one interactive overlay surface per display, at a level above normal windows, with keyboard focus routing. | Expose whether an interactive global overlay is possible. |
| `PointerKeyboardInput` | Deliver pointer motion/drag/click, modifier state, physical key identity, focus and cancel events. | Do not synthesize a global key stream where the OS forbids it. |
| `HotkeyProvider` | Register/unregister global actions and report collisions or unavailable scope. | Settings must show failure instead of claiming a shortcut works. |
| `WindowProvider` | Enumerate visible application windows with bounds, title/app identity and stable ID. | Window mode may be disabled when the desktop security model hides windows. |
| `ClipboardProvider` | Write PNG and a native lossless image representation; write sampled color text. | Report per-format availability. |
| `FileDialogProvider` | Save file with PNG/JPEG filter, filename suggestion and chosen directory. | Cancel is not an error; access failures are explicit. |
| `SettingsProvider` | Read/write versioned user settings and migrate older versions. | Corrupt settings fall back to defaults without losing the session. |
| `PrintProvider` | Optional native print operation. | Capability may be false; Copy and Save remain independent. |
| `LocalizationProvider` | Resolve locale keys with English fallback. | Missing keys are test failures, not raw key text in a release. |

## Platform capability matrix

The exact APIs and permissions must be checked against the OS versions supported by a future
port. The table is an architectural starting point, not an implementation promise.

| Capability | macOS reference | Windows target | Linux/X11 target | Linux/Wayland target |
|---|---|---|---|---|
| Display pixels | ScreenCaptureKit + `NSScreen` | DXGI Desktop Duplication or Windows Graphics Capture + display APIs | X11 capture such as XComposite/XShm, compositor permitting | PipeWire via xdg-desktop-portal; user consent is part of the flow |
| Window list | ScreenCaptureKit shareable content | `EnumWindows`/DWM, filtered to visible app windows | EWMH/ICCCM properties and XComposite | Usually unavailable generically; disable or replace Window mode |
| Full-display overlay | shielding-level AppKit window | borderless topmost layered/transparent window or native compositor surface | override-redirect or compositor-supported top-level surface | layer-shell/compositor-specific; not universally available |
| Global hotkey | Carbon `RegisterEventHotKey` | `RegisterHotKey` or a carefully scoped low-level mechanism | XGrabKey, subject to WM/desktop conflicts | no portable global API; desktop portal/DE-specific integration |
| Clipboard | `NSPasteboard` | Win32 clipboard / Windows clipboard APIs | X11 selections | Wayland clipboard protocol through toolkit |
| Save dialog | `NSSavePanel` | Win32/WinUI common dialog | GTK/Qt dialog | toolkit/desktop portal dialog |
| Print | `NSPrintOperation` | Windows print APIs | CUPS/GTK/Qt print APIs | same, through the chosen toolkit |
| Settings | `UserDefaults` | `%APPDATA%`/`%LOCALAPPDATA%` versioned file | XDG config/data directories | XDG config/data directories |
| Packaging | DMG, ad-hoc/Developer ID signing, optional notarization | MSIX or signed installer/ZIP | AppImage, Flatpak, and/or distro packages | Flatpak is often the most predictable sandbox target |

### Windows notes

- Use a capture API that can produce an immutable frame for every monitor with its actual
  pixel size and scale. Do not assume one system DPI; mixed-DPI desktops are a required test.
- Desktop Duplication is a strong fit for a frozen desktop image and per-display capture;
  Windows Graphics Capture may provide a more modern permission/user-consent path. Pick one
  as the backend and keep the core unaware of the choice.
- A topmost transparent overlay must not accidentally capture itself or block the save dialog.
  The implementation needs an explicit exclusion/ordering policy equivalent to the macOS
  shielding-window handling.
- `RegisterHotKey` reports collisions. Preserve the current Settings behaviour: a failed
  registration is visible and does not silently look active.
- Test per-monitor DPI awareness, mixed scaling, display arrangement changes, secure desktop,
  UAC windows, HDR/color profiles, and displays being disconnected during a session.

### Linux/X11 notes

- X11 gives more control over screen pixels, global key grabs, window enumeration and top-level
  overlays, but behaviour differs between window managers and compositors.
- Test both composited and non-composited desktops, multiple X screens/monitors, negative
  coordinates, mixed scale conventions, and key-grab conflicts.
- Avoid assuming EWMH metadata is complete. Window titles, owner identity and client bounds can
  be missing or decorated differently by the WM.

### Linux/Wayland notes

- Wayland intentionally restricts arbitrary screen reads, global key logging, global window
  enumeration and unrestricted top-level overlays. A port must not bypass those boundaries.
- Use the xdg-desktop-portal/PipeWire flow for screen capture where available. The user may
  need to choose a monitor or window through a system dialog, which changes the current
  “capture every display, then choose locally” flow.
- Window mode, global hotkeys, and a cross-desktop full-screen interactive overlay may be
  unavailable. Represent those as capabilities in the UI and documentation.
- A first Wayland release may reasonably support capture of a user-approved monitor/window,
  local annotation, save and clipboard while leaving global shortcuts and Window mode to
  desktop-specific integrations.

## Rendering and coordinate portability

The portable core should operate on explicit values:

```text
DisplaySnapshot {
  id: StableDisplayID
  desktopRect: LogicalRect       // may have negative x/y
  pixelSize: PixelSize
  scale: ScaleFactor
  rotation: DisplayRotation
  pixels: OpaquePixelImage       // immutable, known orientation and color space
}

Selection {
  displayID: StableDisplayID
  localRect: LogicalRect
}
```

Required conversion tests:

- desktop origin above, below, left and right of the primary display;
- one display at 1× and one at 2× or a fractional scale;
- display rotation if the platform reports it;
- selection edges on half-point coordinates and exact pixel boundaries;
- image buffers whose Y axis differs from the UI coordinate axis;
- output crop clipped to the owning display, never to an arbitrary union rectangle.

Keep color handling explicit too: the reference output is sRGB, alpha is premultiplied in the
current bitmap contexts, and JPEG is only valid for the final opaque screenshot. A port may use
another image library, but must produce equivalent PNG/JPEG pixels and preserve annotation
compositing order.

## Acceptance scenarios for a port

The following scenarios define “works” more precisely than a screenshot of the UI:

1. Capture with one display, select an area, draw every tool, copy PNG, save PNG/JPEG, and
   verify the dimensions and pixels.
2. Capture with two displays at different scales and non-zero/negative desktop coordinates;
   select on display A, select on display B, press Undo, and verify the selection and focus
   return to A; press Redo and verify B returns.
3. Put annotations under a pixelation/blur region; confirm they remain visible both live and
   in the exported image.
4. Draw, partially erase, draw again over the erased area; confirm order and undo/redo.
5. Add text, edit it by clicking it, erase across it, and confirm it can no longer be edited
   until the erase is undone.
6. Use object eraser mode and confirm a click removes exactly the topmost hit annotation.
7. Change primary and backdrop colors alternately; confirm the recent lists remain independent
   and capped at nine.
8. Use a non-Latin keyboard layout and verify physical-key tool shortcuts; create a hotkey
   collision and verify it is visible.
9. Deny capture permission, retry, grant permission, restart if required by the platform, and
   confirm the error path is actionable without leaving a stuck overlay.
10. Change display arrangement or disconnect a display between captures; verify stale last-area
    data is rejected and a new capture still works.

## Packaging and release expectations

Each platform release should publish:

- a versioned installer or archive;
- a checksum generated from the exact uploaded file;
- architecture information (for example x64/arm64 or a universal package);
- permission and first-launch instructions;
- a reproducible build command and the commit/tag used;
- automated core/render tests and a platform manual-test report.

The macOS workflow is the reference for this discipline: a `v*` tag drives a universal build,
self-test, artifact upload, version verification, and a GitHub Release. A future Windows/Linux
workflow should keep the same gates while replacing only the platform build and packaging
steps.

## Open decisions before implementation

These must be decided and documented before a port is advertised as supported:

- shared-core language and FFI boundary;
- UI toolkit per platform;
- minimum Windows version and whether ARM64 is supported;
- X11 support policy and the minimum Wayland/portal versions;
- whether Wayland is a reduced-capability target or a separate product mode;
- image library and color-management policy;
- installer signing/notarization and update policy;
- accessibility strategy for the overlay, tool strip, text editor and keyboard shortcuts.
