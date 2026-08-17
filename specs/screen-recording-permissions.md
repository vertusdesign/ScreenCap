# Screen Recording Permission Flow for macOS Apps

**Status:** normative implementation specification
**Scope:** apps that need macOS Screen Recording access to read pixels, take still captures,
enumerate on-screen windows, or use ScreenCaptureKit
**Intended reuse:** this document is a baseline for ScreenCap and for future macOS apps. A
Windows or Linux port should preserve the same user-visible state machine, while replacing the
platform adapter and permission APIs.

## 1. Goals

The permission flow must:

- give macOS the first opportunity to explain and request access;
- never show an app-owned alert on top of, or at the same time as, Apple's native prompt;
- recover cleanly after a denial, a previously answered prompt, or a stale permission check;
- provide one predictable route to the exact System Settings page;
- keep permission handling in the capture/platform adapter, not in annotation or rendering code;
- request only Screen Recording access when the app does not need other protected capabilities.

The flow must not assume that macOS will display its native prompt again. TCC may remember a
previous answer and return immediately without presenting a new window.

## 2. Sources of truth

Use two checks with different responsibilities:

| Check | Role | Rule |
|---|---|---|
| `CGPreflightScreenCaptureAccess()` | Fast hint for menu state and launch decisions | Never treat a `false` result as proof that a capture will fail. It can be stale after a grant or a code-signature change. |
| A live `SCShareableContent` query, or the equivalent capture API on another platform | Authoritative runtime check | Use it after a request and when capture actually starts. A successful query confirms access. |

Keep an in-process `confirmedPermission` flag only as a positive cache. Set it after a live
query succeeds; do not cache a denial permanently. Recheck after a user returns from System
Settings or after a capture attempt fails.

The app's bundle identifier, signing identity and entitlements must be stable between builds
when possible. macOS associates TCC decisions with the code identity, so an ad-hoc rebuild can
look like a new app and legitimately require approval again.

### Production update versus parallel QA

ScreenCap 3.0.0 production builds intentionally keep the v2 identity
`com.vertusdesign.ScreenCap`, the `ScreenCap.app` bundle name and the `screencap://` URL scheme.
That is required for an App Store update to remain the same product and lets macOS reuse the
existing Screen Recording decision when the signing identity is unchanged. Do not ship a
different production bundle ID merely to obtain a second permission row.

For local side-by-side QA, `make app BUILD_FLAVOR=parallel` substitutes
`com.vertusdesign.ScreenCap.Pro3QA`, `ScreenCap-Pro3-QA.app` and `screencap-pro3://`. This
flavor is a separate TCC/defaults identity and may be opened next to v2, but it must not be
copied to `/Applications` or uploaded to App Store Connect. The Makefile refuses the parallel
flavor's `install` target. Both flavors may register movie document types; use the distinct URL
scheme when invoking a specific build.

## 3. State model

The implementation may use different names, but it must represent these states and guards:

```text
Unknown / not checked
Native request in flight
Access confirmed
Access missing after request
App fallback alert visible
```

`Native request in flight` is a mutex: a second launch event, menu click, or capture failure
must not start another request or show another fallback alert. The fallback alert itself also
needs a guard so repeated events cannot stack modal windows.

## 4. Normative algorithm

### 4.1 Application launch

1. Start the app and finish creating the status item and main application objects.
2. Check the cheap preflight hint. If access is already available, do nothing else.
3. If access is missing, schedule one native `CGRequestScreenCaptureAccess()` call after the
   app has become ready. A short main-run-loop delay is acceptable so the status item and app
   activation are settled.
4. Mark this request as an **initial request**. Do not show the app-owned fallback alert from
   this path, even if macOS returns immediately with `false`. This guarantees that a first-time
   native dialog is never accompanied by a second app dialog.
5. After the native call completes, perform a live ScreenCaptureKit permission check. If it
   succeeds, mark access confirmed. If it fails, leave the app ready for the retry flow.

### 4.2 Capture attempt

1. Do not block every capture solely because the preflight hint is `false`.
2. Attempt the real capture through the platform adapter.
3. If the capture succeeds, treat access as confirmed.
4. If the adapter reports permission denied, start the retry request flow with the fallback
   enabled. Other capture errors must be reported as capture errors, not permission errors.

### 4.3 Retry request flow

Use this flow for a failed capture, the status-menu warning item, or another explicit user
action after the initial request:

1. Acquire the `request in flight` guard. If it is already held, return.
2. Call the native permission request API. Run a blocking API away from the main thread when
   required by the platform, but marshal all UI work back to the main thread.
3. When the native call returns, release the in-flight guard only after the live permission
   check has completed.
4. Run the live check. If it succeeds, mark access confirmed, refresh the menu and finish.
5. If it still fails, show the app-owned fallback alert **only now**. It must be impossible for
   this alert to overlap the native prompt.
6. If the user chooses “Open Settings”, open the exact Screen Recording pane. If the user
   chooses “Later”, close the alert without opening any settings window.

### 4.4 Fallback alert

The alert should say why access is needed and provide exactly two meaningful choices:

- **Open Settings** — opens the Screen Recording permission pane;
- **Later** — dismisses the explanation.

Do not open System Settings automatically from the fallback path. The user must explicitly
choose the button. Bring the app to the foreground before showing the alert so it cannot be
lost behind another application's windows.

For the current macOS implementation, use:

```text
x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture
```

System Settings can lose the deep-link anchor while it is starting from a cold launch. If it
was not running before the link was opened, repeat the same link once after a short delay
(approximately 0.8 seconds). Do not use a broad Security & Privacy URL when an exact pane URL
is available.

### 4.5 Status-menu warning

When access is not confirmed, put a warning item first in the status-menu popup, followed by a
separator. Use an exclamation-triangle icon. Selecting it must call the same retry request flow
as a failed capture; it must not bypass the native request and jump straight to System Settings.

When a live check confirms access, remove the warning item on the next menu update.

## 5. macOS reference pseudocode

This is deliberately platform-adapter pseudocode, not a drop-in implementation:

```swift
func requestPermission(initialRequest: Bool) {
    guard !requestInFlight else { return }
    requestInFlight = true

    runNativeRequest { _ in
        runLiveCaptureCheck { granted in
            onMainThread {
                requestInFlight = false
                if granted {
                    confirmedPermission = true
                    refreshPermissionUI()
                } else if !initialRequest {
                    showFallbackAlertOnce()
                }
            }
        }
    }
}

func capture() {
    adapter.capture { result in
        switch result {
        case .success(let image): use(image)
        case .permissionDenied: requestPermission(initialRequest: false)
        case .failure(let error): showCaptureError(error)
        }
    }
}
```

The real adapter must define how `runNativeRequest`, `runLiveCaptureCheck`, and the deep link
work on the target OS. The core must receive a typed permission-denied result rather than
trying to inspect platform error strings.

## 6. Failure and recovery rules

- A remembered denial is not an exceptional terminal state. The user can retry from the menu,
  after a failed capture, or from another explicit permission action.
- If macOS does not show a native dialog on a retry, the app-owned fallback is the expected
  recovery UI.
- If the user grants access in System Settings while the app is open, run the live check when
  the app next captures or when the settings window returns focus. A restart may still be
  required by the OS; tell the user so when appropriate.
- If the code signature changes, treat a stale or missing grant as normal and repeat the same
  flow. Do not create a second permission system inside the app.
- Do not request Accessibility permission for a screenshot-only app. Add it only when a
  separate feature genuinely requires global input or window manipulation beyond the capture
  contract.
- Test the update path with a production-signed v2 build before release: the bundle ID and
  signing identity must remain stable, and an existing grant must be reused rather than
  prompting for a second app. Test the parallel QA flavor separately and expect its own row.
- Never use a polling loop to wait for permission. Use request completion, app activation, or
  the next user action to trigger a live check.

## 7. Acceptance matrix

Every implementation based on this specification should verify at least:

| Scenario | Expected result |
|---|---|
| Fresh install, access not determined | One native macOS prompt; no app-owned alert at the same time. |
| User allows the first prompt | Live check confirms access; warning menu item disappears. |
| User denies the first prompt | No simultaneous app alert; the app remains usable and can retry later. |
| Retry after denial | Native request is attempted; if macOS shows nothing, one app fallback alert appears. |
| Status-menu warning selected | Same retry flow as above; it does not jump directly to generic settings. |
| Fallback → Open Settings, Settings cold | Exact Screen Recording pane opens; one delayed retry repairs a lost anchor if needed. |
| Fallback → Later | Alert closes; no settings window opens. |
| Two triggers arrive together | One native request and at most one fallback alert. |
| Permission granted while app is running | Next live check succeeds; capture proceeds or the menu refreshes. |
| Capture fails for a non-permission reason | Only the capture error is shown; permission UI is not invoked. |
| Build/signature changes | A new approval may be required, but the same recovery algorithm is used. |

## 8. ScreenCap mapping

The reference implementation maps the rules above as follows:

- launch orchestration: `Sources/ScreenCap/App/AppDelegate.swift`;
- retry and fallback UI: `Sources/ScreenCap/App/CaptureController.swift`;
- preflight, native request, live ScreenCaptureKit check and deep link:
  `Sources/ScreenCap/Capture/ScreenCapture.swift`;
- status-menu warning item: `Sources/ScreenCap/App/StatusItemController.swift`.

When porting this flow, keep this section as an implementation map, but preserve sections 1–7
as the reusable contract. Only the platform adapter and the user-facing wording should need
to change.
