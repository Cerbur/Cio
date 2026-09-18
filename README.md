# NativeBrowser

A macOS-only Chromium browser shell: **SwiftUI + AppKit + Objective-C++ + CEF**
(Chromium Embedded Framework). No Electron, no WKWebView, no Chromium fork.

This repository currently implements **Milestone 0 — Project Bootstrapping**
and **Milestone 1 — One Chromium Tab** from `ARCHITECTURE.md`:

Milestone 0:

- macOS SwiftUI application that launches
- `AppDelegate` (AppKit lifecycle) available and wired up
- AppKit interoperability in place (`NSViewRepresentable` -> `NSView` container)
- CEF framework integrated into the build
- Chromium helper process applications configured in the app bundle
- CEF initialized at startup and shut down cleanly at termination

Milestone 1:

- one `ChromiumView` rendering a real Chromium browser inside an NSView
- `https://www.google.com` loaded at launch
- the browser view resizes with the window
- navigation callbacks: title, URL, loading state, loading progress, load errors
- page receives mouse and keyboard focus (clicking and typing work in the page)
- closing the application destroys the browser before CEF shuts down

Tabs, sidebar, command bar, history, downloads and spaces are **not** part of
these milestones.

---

## Requirements

| Requirement | Version used |
| --- | --- |
| macOS | 26.0+ (built and verified on macOS 27) |
| Xcode | 27.0 |
| Swift | 6.x language mode |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | `brew install xcodegen` |
| CEF | 152.0.6 (downloaded by `Scripts/fetch_cef.sh`) |

The CEF binary distribution (~300 MB download, ~1 GB extracted) is **not**
committed; it is fetched into `ThirdParty/CEF` and ignored by git. Only
`project.yml` is committed — `NativeBrowser.xcodeproj` is generated.

## Build

```bash
Scripts/fetch_cef.sh     # once: download + extract CEF 152.0.6 (macOS arm64)
Scripts/build.sh         # xcodegen generate + xcodebuild (DerivedData in ./build)
```

`Scripts/build.sh` accepts extra `xcodebuild` arguments, e.g.
`Scripts/build.sh -configuration Release`. Build products land in
`build/DerivedData/Build/Products/<Configuration>/NativeBrowser.app`.

The Xcode project can also be used directly:

```bash
xcodegen generate
open NativeBrowser.xcodeproj
```

## Verify

```bash
Scripts/verify_milestone0.sh    # CEF lifecycle, framework, helpers, signature
Scripts/verify_milestone1.sh    # browser content, callbacks, resize, clean quit
```

Milestone 1 is checked end to end:

1. `NativeBrowser --browser-self-test` creates a window and the Chromium
   browser, loads `https://www.google.com`, reports the page title and URL,
   resizes the window and confirms the Chromium view tracked it, then closes
   the browser and shuts CEF down.
2. `NativeBrowser --quit-after=10` runs the real application: the SwiftUI
   window and the AppKit container come up, the page loads and takes keyboard
   focus, and quitting destroys the browser before CEF shuts down without
   hanging.

Manual verification:

```bash
open build/DerivedData/Build/Products/Debug/NativeBrowser.app
```

Expected: a 1280x800 window showing google.com with a thin status line (page
title, URL, loading state) below it. Scrolling, clicking and typing work in the
page; resizing the window re-lays out the page; ⌘Q quits immediately and
cleanly.

The Milestone 0 script checks the CEF lifecycle, framework and helpers:

1. `NativeBrowser --cef-self-test` initializes CEF, pumps its message loop,
   shuts CEF down and exits 0.
2. `NativeBrowser --quit-after=5` launches the real application, reports that
   the SwiftUI window and the AppKit container view came up, terminates through
   the normal AppKit path and shuts CEF down cleanly.
3. The CEF framework is embedded and loaded at runtime (never linked directly).
4. All five `NativeBrowser Helper*.app` bundles exist, have the expected bundle
   identifiers and load the framework at runtime.
5. `codesign --verify --deep --strict` passes for the app, framework and helpers.

Use the manual verification described above.

## Layout

```text
NativeBrowser/
  App/
    BrowserMain.swift          # process entry point: sub-process hand-off, CEF init, app run, CEF shutdown
    NativeBrowserApp.swift     # SwiftUI App/Scene (no @main; BrowserMain owns startup)
    AppDelegate.swift          # AppKit lifecycle, message pump start/stop
    ApplicationRuntime.swift   # app-scoped CEF runtime state and message pump
    Logging.swift              # OSLog categories
  Bridge/
    CEFProcessHost.h/.mm       # Objective-C++ CEF lifecycle boundary (no C++ types leak to Swift)
    BrowserBridge.h/.mm        # Objective-C++ boundary around one Chromium browser
    CEFClientHandler.h/.mm     # CefClient: Chromium callbacks -> BrowserBridge events
    NSApplication+CefSupport.mm# CefAppProtocol support required by CEF on macOS
    NativeBrowser-Bridging-Header.h
  Browser/
    BrowserSession.swift       # runtime session for one browser (not persisted)
    ChromiumView.swift         # NSViewRepresentable wrapper
    ChromiumContainerView.swift# AppKit container that hosts the Chromium view
  Helper/
    HelperMain.mm              # main() of the Chromium helper processes
  UI/Main/
    MainWindowView.swift       # Chromium view + read-only status line
  Resources/
    Info.plist
Scripts/
  fetch_cef.sh                 # download + checksum + extract CEF
  build_cef_wrapper.sh         # build libcef_dll_wrapper.a from libcef_dll sources
  compile_cef_wrapper_source.sh# per-file wrapper compile (driven by xargs -P)
  package_cef_runtime.sh       # Xcode build phase: framework + helper apps + nested signing
  build.sh                     # xcodegen + xcodebuild
  verify_milestone0.sh         # Milestone 0 acceptance checks
  verify_milestone1.sh         # Milestone 1 acceptance checks
project.yml                    # XcodeGen project definition (source of truth)
```

## Architecture decisions

1. **The CEF framework is loaded at runtime, not linked.**
   On macOS the framework must be loaded from the app bundle *after* process
   start (`CefScopedLibraryLoader`), because that is what the Chromium sandbox
   implementation requires and what the CEF binary distribution expects. The app
   links only `libcef_dll_wrapper.a`; `otool -L` shows no CEF dependency.

2. **Helper processes are separate executables, not copies of the app binary.**
   `NativeBrowserHelper` (a tiny tool target) is copied into the five
   `NativeBrowser Helper*.app` bundles that CEF looks up by process type
   (``, `Alerts`, `GPU`, `Plugin`, `Renderer`). Each helper loads the framework
   from the browser process's bundle via `../../..`, so the 323 MB framework is
   stored exactly once.

3. **The bundle is assembled by a build phase.** `Scripts/package_cef_runtime.sh`
   runs after linking and before Xcode signs the app, creating the versioned
   framework layout and the helper bundles, and signing nested code inside-out.

4. **The app owns the message loop.** CEF is initialized with
   `external_message_pump = true`; `CefDoMessageLoopWork()` is driven by a timer
   on the main run loop, because SwiftUI owns the `NSApplication` run loop.

5. **Lifecycle ordering lives in one place.** `BrowserMain` performs the CEF
   sub-process hand-off, then `CefInitialize`, then runs the SwiftUI app, then
   `CefShutdown`; `-applicationWillTerminate:` performs the same shutdown for the
   normal quit path. Both are idempotent. No view owns CEF lifecycle logic.

6. **Swift never sees a CEF C++ type.** `CEFProcessHost` exposes only
   `NSObject`/`NSString`/`NSError`/`BOOL`/scalars across the bridge.

7. **XcodeGen is the source of truth.** `NativeBrowser.xcodeproj` is generated;
   the wrapper library, framework packaging and helper bundling are all scripted
   so a CEF upgrade is a version bump plus a clean build.

### Milestone 1

8. **One browser per session, owned by the application.** `BrowserSession`
   (Swift, runtime-only, not `Codable`) drives `BrowserBridge` (Objective-C++),
   which owns the only `CefBrowser` reference. The application runtime keeps the
   list of live sessions so termination can close every browser before
   `CefShutdown()`.

9. **The browser is created when its container is in a window.** CEF attaches its
   own `CefBrowserHostView` to the container view, so creation happens from
   `viewDidMoveToWindow`, not from SwiftUI's `makeNSView`.

10. **Closing a browser means releasing its view.** CEF implements
    `AlloyBrowserHostImpl::WindowDestroyed()` in `CefBrowserHostView`'s
    `-dealloc`: the browser is destroyed only when that view actually
    deallocates. `-completeClose` therefore removes the view from the hierarchy
    inside an explicit autorelease pool and drops its strong reference — without
    that, ARC keeps the view alive, `OnBeforeClose` never arrives, and quitting
    only completes when `CefShutdown()` forces the teardown (a multi-second
    hang). `DoClose()` returns true because the application owns the window, so
    CEF does not try to send it a `performClose:` that a non-key window ignores.

11. **CEF needs `CefAppProtocol` on NSApplication.** Chromium dispatches native
    keyboard/IME events synchronously and reads
    `-[NSApplication isHandlingSendEvent]`. CEF's samples subclass
    `NSApplication`, which a SwiftUI app cannot do (CEF creates the application
    object during `CefInitialize`, before SwiftUI starts, so `NSPrincipalClass`
    is not consulted). `NSApplication+CefSupport.mm` implements the protocol and
    wraps `-sendEvent:` once, exactly like CEF's reference implementation.

12. **The page is focused as soon as it exists.** `BrowserSession` calls
    `setFocus(true)` when Chromium reports the browser, which makes the Chromium
    view first responder so clicking and typing work without an extra click.

13. **Popups navigate the current browser.** Milestone 1 hosts exactly one
    browser, so allowing a popup would create an unmanaged window;
    `OnBeforePopup` loads the target URL in the existing browser instead.
    Milestone 3 routes popups to a new tab (ARCHITECTURE.md section 21).

14. **Development-only sandbox setting.** The helper applications are not built
    with `CEF_USE_SANDBOX`, so `CefSettings.no_sandbox` is set to true, matching
    CEF's own `-DUSE_SANDBOX=OFF` builds: a sandboxed child expects a bootstrap
    namespace that only `CefScopedSandboxContext` prepares, and without it the
    helper cannot reach the browser process over Mach IPC. Enabling the sandbox
    needs Developer ID signing for the app and its helpers (sections 33 and 34).

## Upgrading CEF

1. Pick a build from <https://cef-builds.spotifycdn.com/index.json>
   (`macosarm64`, stable).
2. Update `CEF_VERSION`/`CEF_SHA1` in `Scripts/fetch_cef.sh`.
3. `rm -rf ThirdParty/CEF ThirdParty/libcef_dll_wrapper.a ThirdParty/wrapper-build`
4. `Scripts/fetch_cef.sh && Scripts/build.sh && Scripts/verify_milestone0.sh && Scripts/verify_milestone1.sh`

`Scripts/build_cef_wrapper.sh` discovers the wrapper sources by globbing
`libcef_dll` (identical to CEF's own `libcef_dll/CMakeLists.txt` for 152.0.6),
so it does not need to be edited for a version bump.

## Not implemented yet

Tabs, sidebar, spaces, command bar (back/forward/reload UI, ⌘L), history,
downloads, session restore, Liquid Glass styling — see `ARCHITECTURE.md`
milestones 2-8. The status line below the browser view is a read-only
placeholder for the Milestone 2 command bar.
