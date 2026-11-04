# Recorder AAC startup compatibility

## Confirmed failure and scope

On the affected Mac, requesting AAC at 16 kHz mono and 192,000 bit/s causes
`AVAssetWriter.startWriting()` to reject the configuration with
`AVFoundationErrorDomain -11861` (`unsupportedOutputSettings`, displayed as
`Cannot Encode Media`), underlying OSStatus `-12651`. Synthetic tests reproduce
the same failure at 8, 16 and 24 kHz. The same inputs work with inferred output
parameters or compatible 48 kHz AAC settings.

Explicit sample rate/channel count are not inherently wrong. The unsupported
combination of bitrate and output format caused this regression. Keep
`sourceFormatHint`, but let AVFoundation choose the output rate/channel count
for the normal recording path. Capture sample counts and timestamps remain in
the source clock; AAC resampling must not retime the input buffers.

The earlier Bluetooth duration correction is independent: malformed/overlapping
PCM buffers are normalized before muting, microphone DSP, startup buffering and
encoding. This correction remains active for both startup profiles. The
PTS-based correction requires evidence of overlap in both consecutive packets;
valid variable-sized packets, near-duplicate timestamps and format changes
do not supply that evidence. Overlap detection is a heuristic and still requires real-route
validation; an encoding test cannot establish correctness for every device.

## Startup flow

1. Retain the original bounded startup queue. Construct video and every available
   requested audio input locally, with their stable track roles.
2. Try the normal AAC profile (source format hint; existing target bitrates).
3. Only if `startWriting()` rejects encoding settings before any media is
   submitted, cancel that writer and create a fresh writer and inputs.
4. Retry once with AAC at 48 kHz, 64,000 bit/s mono or 128,000 bit/s stereo.
   For unexpected multichannel formats, retain the source hint/layout and let
   AVFoundation choose the encoding settings rather than silently downmixing.
5. On success, set the original timeline origin and start the media session.
   If audio preceded the first complete image, hold that image over the empty
   video prefix before draining every original pending buffer once. Track
   metadata, audio timestamps, fragment interval, codec and recovery marker
   are preserved.
6. On failure, stop with the actual error. No further retries and no fallback
   that drops a requested audio track.

Retries do not apply to disk-full, permission, volume, cancellation, temporary
encoder availability or explicitly identified video-format failures. No retry
occurs after samples have started writing. Format/route changes during an
ongoing session need a separate recovery policy.

The only removable retry artifact is the unsuccessful attempt's partial MOV,
before any media submission. Final recordings and recovery markers are outside
this cleanup. Cleanup errors abort the retry and retain their original details.
Diagnostics record input rates/channels, rejected NSError details and the
successful profile.

## Leading black frame: empty movie edit (2026-10-15)

Read-only inspection of an affected recording on 2026-10-15 found a 13.333 ms
empty video edit at time zero, followed by the first real image at 13.333 ms.
AVAssetReader synthesizes an all-black image for the empty edit. The first
actual captured image was not black. The existing ScreenCaptureKit guard
already rejects lifecycle/blank surfaces and remains in place for both BGRA
and 420v. Extending that darkness filter cannot remove a container edit.

The common movie origin is still the earliest available source timestamp.
`RecorderVideoTimeline.leadingFrame` makes one raw sample referencing the
first accepted image, at that common origin, with duration exactly equal to
the leading gap. The writer inserts it before the original image samples.
Original samples retain their PTS, duration and pixel data. Early audio is
preserved, later microphone onset stays at its captured offset, and no sample
count/sample-rate correction or AAC profile changes. Video already starting
at the origin receives no extra sample. This applies to every available-track
startup, including the grace-period/stop path, and precedes recovery/composite
rewriting, so the raw partial also has a real first image.

This intentionally holds the earliest available real picture briefly before
its capture time. There is no captured picture for that audio-only interval;
discarding early audio or shifting only video would change the recorded data
or synchronization. A deliberately dark first accepted image remains dark.
This fix affects new recordings; it does not rewrite existing movies.

## Automated regression check

From the public checkout:

```bash
swiftc -swift-version 6 -parse-as-library \
  Sources/ScreenCap/Recorder/RecorderWriterStartup.swift \
  Sources/ScreenCap/Recorder/RecorderAudioTimelineNormalizer.swift \
  Sources/ScreenCap/Recorder/RecorderVideoTimeline.swift \
  Sources/ScreenCap/Recorder/ScreenCapTrackMetadata.swift \
  Scripts/test-recorder-startup.swift \
  -o /tmp/screencap-recorder-startup-tests
/tmp/screencap-recorder-startup-tests
```

This does not capture the screen or microphone and does not launch the app.
It creates small synthetic movies in a fresh temporary folder and uses the
production startup/normalizer/track-metadata code. It checks:

- normal startup without a retry;
- an actual rejected 16 kHz/192 kbps configuration followed by compatible AAC;
- fallback plus Bluetooth-style overlapping PCM buffers;
- preservation of valid variable-sized packets and near-duplicate timestamps;
- decoded, non-silent microphone/system audio, stable roles and video;
- movie/audio durations of approximately one second, including overlap input;
- at most two attempts, no audio retry for video-only recording;
- retry filtering for disk/access/temporary-encoder and known-video failures;
- a control reproducing the original empty leading edit when video starts
  after audio;
- video delays of 14 ms and 350 ms, including AAC fallback + overlapping PCM;
- decoded non-black images at zero, no leading empty edit, unchanged audio
  onset, and approximately one-second duration before/after passthrough export.

When compiled in an isolated copy of the app target with its normal entry
point replaced by this runner and `SCREENCAP_RECORDER_INTEGRATION_TESTS`
defined, the same script also exercises the real `RecorderWriterService` and
`RecorderPostProcessor`. It verifies the finalized video, both named original
audio tracks and composite, a microphone starting 60 ms later than system
audio, a muted continuous system track, microphone-only and video-only recording, and the two video
startup delays. This runner does not start an application UI or capture real
screen/microphone data. All generated media/recovery markers stay in its fresh
temporary directory.

During the public-release integration pass, composite rewriting was also
checked with system audio disabled. Source roles must be read from track
metadata: the first original stream in that case is a microphone, not system
audio. A derived microphone reader must have its output added before it starts.
Both conditions are enforced in the post-processor; optional echo reduction
remains off by default in the public product.

Expected result: `PASS all recorder startup regression checks`. Deliberately
rejected configurations are expected in this test's diagnostic output.

## Manual acceptance after installing the fixed build

1. Enable system audio and microphone. Select the previously failing Bluetooth
   microphone. Record for 30–60 seconds, play some system audio and speak at
   known points near the beginning and end. Stop normally.
2. Confirm that recording starts, the duration matches elapsed time (within
   about a second), and both original audio tracks exist and are audible when
   enabled individually in Track Editor. Check synchronization near both ends.
3. Repeat with the built-in microphone, microphone disabled, system audio
   disabled and both disabled. Two original audio tracks are expected only
   when both sources were requested and emitted data.
4. With the Bluetooth route, record for at least five minutes and check duration
   and synchronization at the end. This catches accumulating duration errors
   that a short synthetic test cannot detect.
5. Inspect `~/Library/Logs/ScreenCap/recorder.log` if needed. Normal starts report
   `audioProfile=automatic`. A successful fallback reports the rejection,
   `retrying with compatible AAC` and then `audioProfile=compatible`. Absence
   of a fallback on a supported route is expected.

Do not require the live app to fail artificially to validate fallback: the
automated regression deliberately forces rejection without altering production
defaults or exposing a fault-injection setting to users.

## References

- Apple, [AVAssetWriterInput](https://developer.apple.com/documentation/avfoundation/avassetwriterinput):
  its `sourceFormatHint` initializer permits incomplete output settings;
  AVFoundation chooses remaining parameters considering the input format.
- Apple, [AVAssetWriter](https://developer.apple.com/documentation/avfoundation/avassetwriter):
  startup and writer status/error handling.
- Installed Apple SDK headers `AVAssetWriterInput.h` and `AVError.h` document
  missing audio output fields with a format hint and error `-11861`.
