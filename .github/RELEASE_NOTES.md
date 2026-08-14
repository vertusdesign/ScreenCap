ScreenCap 2.2.0 improves long-recording output reliability and the opened-image editing workflow.

### Improvements

- Long recordings use bounded writer backpressure, explicit overflow handling and final QuickTime
  movie validation, so incomplete video is reported instead of being silently accepted.
- Video saving keeps valid timestamps and handles AVFoundation's metadata-only boundary samples
  without rejecting an otherwise playable movie.
- Images opened from Finder start at 100% scale, centre when possible, and can be panned with a
  trackpad gesture or mouse wheel from any annotation tool.
- Opened-image panning follows macOS's Natural scrolling preference.
- Saving an opened image without confirmation prefers the source folder and adds `_ScreenCap`
  before the extension, with a Save Panel fallback when that folder is unavailable.
- Extending an opened image's edge expands the scrollable canvas and fills only the new area with
  the current primary colour.

The screenshot path remains independent of screen recording.
