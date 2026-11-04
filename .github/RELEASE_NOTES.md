ScreenCap 3.0.1 improves screen-recording reliability.

- Fixed black frames at the beginning of recordings when audio starts before the first screen image.
- Fixed incorrect recording duration caused by malformed or overlapping Bluetooth microphone audio buffers.
- Added a safe AAC startup fallback for unsupported audio settings that could cause recording to fail immediately.
- Improved identification and preservation of original audio tracks during saving and recovery.
- Standardized recovery filenames while retaining support for older recordings.
- Added optional local echo reduction, disabled by default, with original audio tracks preserved.

Includes complete translations for all 24 supported interface languages and a universal build for Apple Silicon and Intel.

Requires macOS 14+ for screenshots and macOS 15+ for screen recording.
