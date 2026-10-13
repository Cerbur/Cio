# Daily browser integration — P0 4/5/6

## Implemented boundaries

- Website requests use Chromium PermissionRequestManager and its original request delegates. Cio presents the origin, requested capabilities, Block, Allow, and supported one-time grants in an AppKit sheet. Location supports the upstream accuracy choice. Permission persistence, enterprise policy and site settings remain Chromium-owned. Tab hiding destroys the prompt while leaving the request pending; navigation/close invalidates its weak callbacks. Native prompts prevent fullscreen/cursor spoofing and Return defaults to Block.
- Screen/audio source pickers retain Chromium's actual selection UI, security dialog tracker, source lists, policies and capture callbacks. The existing WebContents modal dialog manager owns their lifetime; the native sheet adapter supplies Cio's AppKit parent instead of a nonexistent Chrome Views window. No source is selected automatically.
- Camera, microphone and location usage strings are present in the main bundle. Release Hardened Runtime media entitlements are included without bypassing macOS consent. Native Settings links to site permissions and macOS Privacy & Security; the address site's information links directly to its origin's Chromium settings.
- Uploads continue through Chromium's native macOS file dialog and renderer drag/drop handling. Cio's outer URL-drop target only accepts HTTP(S) links, leaving files to Chromium.
- Download progress reaches the application independently of a source BrowserSession via immutable native notifications. Closing a source tab does not remove the application's progress/completion record. The existing per-session callbacks remain available to diagnostics. A rejected Cio destination now returns a file access error instead of falling back silently to a different directory. Application quit asks whether to continue pending downloads or quit and cancel them. Failed rows explain network, server or file errors; Chromium's target reservation, managed-path and safety checks remain in place.
- The bundle registers HTTP/HTTPS. NSApplicationDelegate receives links and queues them until the shell mounts, opening each complete URL in the current workspace. Only HTTP(S) URLs with hosts are accepted; query encoding and fragments are retained. Cio's Settings has a default-browser action using NSWorkspace and reports success only when both schemes resolve to this application. The existing native external-protocol prompt remains Chromium-owned for security checks and user confirmation.

## Automated checks

- Required Debug build via `CONFIGURATION=Debug Scripts/build.sh`: successful.
- Independent XCTest: 193 cases pass, including the new actionable download failure case.
- CioModel: 92 cases pass, including OS URL scheme validation.
- `--download-close-self-test --download-close-url=http://127.0.0.1:18766/slow` runs in the real SwiftUI shell, waits for download progress, closes the source, checks complete source teardown and exact 8 MiB contents, then requests normal app termination. It requires an explicitly isolated `CIO_DATA_DIR`. Operational polling is not a visual animation.
- Add `--download-close-show-library` to render the native Downloads panel before source teardown. `--download-library-self-test` instead keeps the source alive, brings the panel to the foreground and checks the exact completed bytes. Both use the same loopback URL argument and isolated data directory.

## Computer-use evidence (2026-10-13)

All checks bind the repository's freshly built Debug app by absolute path, after checking its new PID and launch arguments. Fixtures listen only on 127.0.0.1; media devices are virtual and upload files contain artificial text. Logs and profiles are in `build/verification/p0-daily/`.

Confirmed:

- AppKit notification denial returns `denied` to the page.
- AppKit microphone one-time grant returns a live virtual audio track; stop succeeds.
- Camera's native permission sheet shows Block, Allow and Allow this time; Block returns `NotAllowedError` to the page.
- Chromium's screen source picker opens as an AppKit sheet and cancellation returns `NotAllowedError`.
- Native file dialog selects two artificial files; both uploads are confirmed by exact received bytes.
- Ordinary HTTP download (32,768 bytes) and Blob download (20 bytes) complete and match their fixtures exactly.
- An interrupted response appears as Failed with an explanation. Cmd+Q during a download presents the native keep-downloading/quit sheet; continuing preserves the process.
- Source-tab close regression passes both under LLDB and as a normal process with Downloads visibly showing ongoing progress after the source disappeared; both reach exact 8 MiB completion and normal termination.
- LaunchServices cold and warm link deliveries are present in the isolated persisted workspace, including unchanged `%2F%26` and `#exact`.

An early interactive process exited with status 139. Later, keeping the source alive and opening Downloads during progress reproduced a stack overflow twice. LLDB captured a repeating `Color.AccentColorProvider` → `NSColor` → `NSAppearance` cycle, including the same cycle 1,000 frames down (`library-live.log`). The progress control's `.tint(Color.accentColor.opacity(...))` was removed so the native control resolves its own system tint. The immediate-source-close diagnostic alone did not catch this: its source disappeared before the active progress appearance was exercised. Concurrent user use was explicitly ruled out.

Final fixed build: `build/p0-final-fixed-build.log` reports BUILD SUCCEEDED. The foreground library regression reports `download-library: PASS foreground panel and exact bytes with live source` and exits 0 (`library-fixed.log`). Computer use then repeated the original source-alive/downloads-panel trigger without crashing. The red window close button showed the pending-download sheet; Continue preserved the same window and progress rose from 10% to 35%. The file later appeared Completed and its exact 8,388,608 bytes were verified. Screen-picker cancellation and camera denial returned `NotAllowedError`, the interrupted response showed Failed with a server explanation, and normal Cmd+Q exited 0 with `cef:shutdown(clean: true)` (`ui-fixed.log`).

The loopback mailto link produced no visible external-app prompt in this environment; outbound external-protocol handoff is therefore not claimed as verified. The existing Chromium-owned protocol/security adapter remains in place. OS-delivered HTTP(S) link handling was verified separately above.

Not established by these synthetic checks: real camera/microphone hardware, actual macOS sensor grants, a real meeting's screen capture, location coordinates, notification delivery, default-browser acceptance, or third-party cloud uploads. These require the appropriate real-device/system interaction and user consent. The Settings action is implemented without changing the user's default browser during development.
