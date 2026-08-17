ScreenCap 3.0.0 adds the native Player module, synchronized track editing and privacy-first
on-device transcription, while retaining the reliable screenshot and screen-recording flows.

The production bundle identity remains compatible with the v2 App Store update path. A separate
`BUILD_FLAVOR=parallel` bundle is available for local side-by-side permission QA only.

### New since 2.0.0

- **Text recognition:** a dedicated toolbar tool uses macOS Live Text to recognize text on the image. Recognized text can be selected and looked-up, translated, or copied. The image itself is not modified.
- **Open images from Finder:** use **Open With → ScreenCap** from Finder to annotate an existing image. Among other features: the image edges can be expanded, which creates additional editable canvas filled with the selected color.

### Screen recording improvements

- **More reliable recordings:** reduced the risk of lost video samples during lengthy or high-resolution recordings.
- **Improved MOV saving:** fixed cases where a recording could be saved with invalid video timing and then appear frozen or behave incorrectly in some third-party video players (such as VLC), even though it played correctly in QuickTime.
- **Final file validation:** ScreenCap now checks the finished movie before confirming that the recording was saved. Incomplete or invalid video is reported instead of being silently accepted.
- **Better compatibility of saved recordings:** video and audio tracks are checked for consistent duration and timeline integrity.

[Full changelog](https://github.com/vertusdesign/ScreenCap/blob/main/CHANGELOG.md)
