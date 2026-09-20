# NativeBrowser

A macOS-only Chromium browser shell: **SwiftUI + AppKit + Objective-C++ + CEF**
(Chromium Embedded Framework). No Electron, no WKWebView, no Chromium fork.

This repository currently implements **Milestone 0 — Project Bootstrapping**,
**Milestone 1 — One Chromium Tab**, **Milestone 2 — Navigation UI**,
**Milestone 3 — Tabs** and **Milestone 4 — Spaces** from `ARCHITECTURE.md`:

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

Milestone 2:

- native navigation toolbar: Back, Forward, Reload/Stop and an address field
- address/search parser (`NavigationInput.swift`) with a Google search fallback
- main-frame URL and page title synchronisation from CEF
- `canGoBack` / `canGoForward` taken from CEF, driving button enablement
- one control that reloads while idle and stops while loading
- ⌘L (focus address field, select all), ⌘R (reload), ⌘[ / ⌘] (back/forward)
- separate committed-URL and edit-buffer state, so a URL callback can never
  overwrite what the user is typing
- Chinese IME works in the address field (native `NSTextField`, no custom key
  interception)

Milestone 3 adds multiple independent tabs, stable Chromium surfaces, managed
popups, focus-safe tab switching and multi-browser shutdown.

Milestone 4 adds in-memory Spaces, per-Space tab ordering and selection,
source-Space popup routing, recently-closed Space restoration and all-Space
shutdown. Persistence, history, downloads, session restore and Liquid Glass
styling are **not** part of these milestones.

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
Scripts/verify_milestone2.sh    # parser, navigation state, shortcuts, navigation, clean quit
Scripts/verify_milestone3.sh    # tab/runtime ownership, focus, popups, shutdown, redaction
Scripts/verify_milestone4.sh    # Spaces model, multi-Space CEF integration, shutdown
Scripts/check_no_secrets.sh     # credential scan of tracked files and git history
```

Milestone 2 is checked end to end:

1. the parser unit tests run through `xcodebuild test` (they never start CEF),
2. `NativeBrowser --parse-navigation-input=...` checks the parser inside the
   shipped binary, without initializing Chromium,
3. `NativeBrowser --navigation-self-test` drives the real navigation stack:
   Google loads, a Chinese query is submitted through the session's address-field
   path, a direct URL navigation updates the address field, Back / Forward /
   Reload / Stop reach CEF, `canGoBack` / `canGoForward` come from Chromium, and
   the browser is created exactly once and destroyed before CEF shuts down,
4. `NativeBrowser --quit-after=10` confirms the real application still quits
   cleanly with the toolbar in place.

Everything that needs a human at the keyboard (⌘L focus, select-all, IME
composition, button enablement as drawn, Escape, resize feel) is printed by the
script as **REQUIRES MANUAL VERIFICATION** and is not claimed as tested.

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

Expected: a 1280x800 window showing google.com with a native navigation
toolbar (← → ↻/× and the address field) above it and a thin title line below it.
The address field shows the main-frame URL; Back and Forward are enabled once
there is somewhere to go; the third control reloads while idle and stops while
loading. ⌘L focuses the address field and selects all of it, ⌘R reloads, ⌘[ and
⌘] go back and forward, Return navigates or searches, Escape cancels an edit.
Scrolling, clicking and typing work in the page; resizing the window re-lays out
the page below the toolbar; ⌘Q quits immediately and cleanly.

The Milestone 2 manual checklist (startup, direct URL, search, Chinese IME,
Back/Forward, reload, stop, focus, redirects, resize, shutdown) is printed by
`Scripts/verify_milestone2.sh` as **REQUIRES MANUAL VERIFICATION**; those items
were not automated.

> Note on `xcodebuild test`: this sandbox cannot give the test runner a pseudo
> terminal, so `Scripts/verify_milestone2.sh` falls back to
> `xcodebuild build-for-testing` plus `xcrun xctest` on the produced bundle.
> That runs the same XCTest bundle, just without Xcode's launcher.

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
    URLLogSanitizer.swift      # the one URL redaction policy for logs and traces
    AppCommands.swift          # browser menu commands: command-L / R / [ / ]
    NavigationSelfTest.swift   # Milestone 2 integration self-test (--navigation-self-test)
    SpacesSelfTest.swift       # Milestones 3/4 runtime self-test (--tabs-self-test/--spaces-self-test)
    NavigationInputProbe.swift # parser probe in the shipped binary (--parse-navigation-input=)
  Bridge/
    CEFProcessHost.h/.mm       # Objective-C++ CEF lifecycle boundary (no C++ types leak to Swift)
    BrowserBridge.h/.mm        # Objective-C++ boundary around one Chromium browser
    CEFClientHandler.h/.mm     # CefClient: Chromium callbacks -> BrowserBridge events
    NSApplication+CefSupport.mm# CefAppProtocol support required by CEF on macOS
    NativeBrowser-Bridging-Header.h
  Browser/
    BrowserSession.swift       # runtime session for one browser (not persisted)
    BrowserSession+Commands.swift # address-field submit/cancel and focus hand-off
    BrowserSessionManager.swift # live runtime sessions, containers and close callbacks
    BrowserWorkspaceStore.swift # application-facing Space/tab policy and transitions
    BrowserSpace.swift          # CEF-free Space value
    WorkspaceCollection.swift   # CEF-free Spaces, tabs and close policy
    NavigationInput.swift      # address/search parser (Foundation only, unit tested)
    ChromiumView.swift         # NSViewRepresentable wrapper
    ChromiumContainerView.swift# AppKit container that hosts the Chromium view
  Helper/
    HelperMain.mm              # main() of the Chromium helper processes
  Tests/
    WorkspaceCollectionTests.swift # pure Space/tab policy tests (no CEF)
    NavigationInputTests.swift # parser unit tests (no CEF, no app host)
    URLLogSanitizerTests.swift # URL log redaction policy tests
    NavigationURLPreservationTests.swift # explicit URLs keep query + fragment
  UI/
    Main/MainWindowView.swift  # toolbar + Chromium view + title line
    CommandBar/
      BrowserToolbarView.swift # Back / Forward / Reload-Stop / address field
      AddressField.swift       # native NSTextField bridge (IME + focus + select-all)
      AddressFieldModel.swift  # committed URL vs. edit buffer
      BrowserCommandNotifications.swift # command-L focus plumbing
  Resources/
    Info.plist
SchemeTemplates/
  NativeBrowser.xcscheme       # shared scheme with the unit-test TestAction
Scripts/
  fetch_cef.sh                 # download + checksum + extract CEF
  build_cef_wrapper.sh         # build libcef_dll_wrapper.a from libcef_dll sources
  compile_cef_wrapper_source.sh# per-file wrapper compile (driven by xargs -P)
  package_cef_runtime.sh       # Xcode build phase: framework + helper apps + nested signing
  build.sh                     # xcodegen + xcodebuild
  sync_scheme.sh               # install SchemeTemplates/ into the generated project
  verify_milestone0.sh         # Milestone 0 acceptance checks
  verify_milestone1.sh         # Milestone 1 acceptance checks
  verify_milestone2.sh         # Milestone 2 acceptance checks
  verify_milestone3.sh         # Milestone 3 acceptance/regression checks
  verify_milestone4.sh         # Milestone 4 acceptance checks
  check_no_secrets.sh          # credential scan (tracked files + git history)
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
   sub-process hand-off, then `CefInitialize`, then runs the SwiftUI app.
   `ApplicationRuntime.Terminator` closes browsers before `CefShutdown`; final
   exit hooks are idempotent and never shut CEF down with live browsers.
   No view owns CEF lifecycle logic.

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

12. **The page is focused as soon as it exists — and only when it should be.**
    Chromium creates a browser asynchronously, and focuses it by itself when its
    first navigation starts. `BrowserSession` therefore takes focus on creation
    only if that session is still the visible selected surface *and* the keyboard
    is still meant for page content (`wantsPageFocus`, set by the one selection
    transition in `BrowserSessionManager`), and it answers Chromium's own focus
    request (`CefFocusHandler::OnSetFocus`, forwarded through `BrowserBridge`)
    with the same rule. A background tab, or a tab that was left behind while its
    browser was still being created, therefore cannot steal the keyboard
    (ARCHITECTURE.md section 56).

13. **Popups navigate the current browser.** Milestone 1 hosts exactly one
    browser, so allowing a popup would create an unmanaged window;
    `OnBeforePopup` loads the target URL in the existing browser instead.
    Milestone 3 routes popups to a new tab (ARCHITECTURE.md section 21).

### Milestone 2

14. **Navigation state is a snapshot, not a second source of truth.**
    `BrowserSession.navigationState` builds a `NavigationState` value from the
    CEF callbacks; the toolbar renders that and calls the session's methods.
    Nothing in the UI keeps its own history or loading state, so `canGoBack` /
    `canGoForward` are always what Chromium reported.

15. **The address field separates the committed URL from the edit buffer.**
    `AddressFieldModel` holds `committedURL` (last main-frame URL from CEF) and
    `editText` (what the user is typing). A URL callback may only write
    `editText` while `isEditing == false`. That is the whole rule — a flag, not
    a timer — so an unrelated callback can never move the text under the
    cursor, and cancelling or submitting returns the field to browser state.

16. **The address field is AppKit (`NSTextField`), not a SwiftUI `TextField`.**
    AppKit's field editor is where macOS handles IME composition (marked text,
    candidate window, commit), and it can be made first responder and
    select-all'ed from outside SwiftUI — both of which ⌘L and Chinese input
    need. No key events are intercepted anywhere in the application.

17. **Browser shortcuts are menu key equivalents.** ⌘L / ⌘R / ⌘[ / ⌘] are items
    in the main menu, which `NSMenu` matches *before* the first responder sees
    the event. That is what makes them work while Chromium owns the keyboard,
    without polling for key events. The shell therefore owns these chords and
    Chromium's own accelerators never see them.

18. **The Chromium view is never rebuilt.** `ChromiumView` is keyed by the
    session and holds no changing inputs; URL, title, loading and address-text
    updates only mutate `@Published` state. `BrowserSession.browserCreationCount`
    exists so the integration test can assert that navigations create exactly
    one browser.

19. **The parser is dependency free and unit tested.**
    `NavigationInput.swift` imports Foundation only and is compiled into both
    the app and the test target, so `xcodebuild build-for-testing` produces a
    test bundle that never starts CEF. `NativeBrowser
    --parse-navigation-input=...` re-checks the same parser inside the shipped
    binary, without initializing Chromium.

20. **Quit returns from the native event before cleaning up CEF.**
    `applicationShouldTerminate` starts the coordinator and returns
    `.terminateCancel`. This lets the Cmd+Q event and enclosing Chromium calls
    unwind. `.terminateLater` is unsafe here: AppKit runs a nested modal loop
    inside `terminate`, retaining the original event stack. Timers can fire
    without that stack returning, leaving the browser view alive and delaying
    `OnBeforeClose` until the five-second fallback.

    The coordinator runs on the default run loop, closes browsers, waits for
    `OnBeforeClose`, and then calls `CefShutdown()` once. It requests termination
    again with a ready flag, so the delegate now returns `.terminateNow`.
    Before detaching the CEF host view, the bridge releases CEF focus and clears
    the window first responder. Otherwise native page-key handling can leave
    the host view alive after detachment. `OnBeforeClose` drives progress; the
    coordinator does not poll or force-release the view after arbitrary turns.
    Repeated quit requests do not restart cleanup. If browser closure times out,
    all application exit paths avoid calling `CefShutdown` with live browsers.

21. **`CefSettings.persist_session_cookies` and the mock keychain.** See the
    troubleshooting section below for why Chromium is kept away from the login
    keychain; that switch also means cookies live only for the process.

22. **Shutdown latency is measured, not guessed.** The termination path is
    instrumented on one monotonic clock (`Bridge/ShutdownTiming.h`) shared by
    Swift, the Objective-C++ bridge and CEF's callbacks, so the phases can be
    attributed rather than assumed. Pass `--log-shutdown-timing` to have the app
    print them:

    ```bash
    NativeBrowser --log-shutdown-timing --wait-for-window --quit-after=8
    # shutdown-phase: T0 +8123.4ms
    # shutdown-phase: T1-CloseBrowser +8123.7ms
    # ...
    ```

    Real Cmd+Q reproduced the old bug even on `about:blank`: five seconds
    followed by SIGTRAP. With cancellation/retry, the same test profile quit
    in about 90 ms with exit 0 and `OnBeforeClose` before `CefShutdown`.
    Navigating through the address field exposed a second case: without focus
    cleanup, real Cmd+Q took 5000 ms; with it, 58 ms. Removing that cleanup
    reproduced the 5000 ms timeout again. Programmatic focus/navigation followed
    by `terminate` did not reproduce it, so real-key coverage is required.
    Programmatic `--quit-after` / `--terminate-in-pump-after` checks do not
    reproduce the native event stack and must not substitute for real Cmd+Q.
    Capture real-key runs with page focus and address-field focus, then check:

    ```bash
    python3 Scripts/check_shutdown_timing.py path/to/quit.log 0
    ```

    Supply the actual process exit code as the second argument. The checker
    requires ordered T0–T7 phases, one CEF shutdown, no fallback, and a quit
    budget of 1000 ms (optional third argument overrides it). It validates a
    recording; it does not itself press Cmd+Q.

### Pre-Milestone-3 security fix: URL redaction

23. **One redaction policy for every URL that is logged.** A browser URL can
    carry a session token (`?token=...`), an OAuth code, a signature, or
    credentials in its user-info or fragment, so no URL is formatted into a log
    by hand. `URLLogSanitizer` (`NativeBrowser/App/URLLogSanitizer.swift`) is
    the single policy:

    ```text
    kept:     scheme, host, port, path, query parameter names
    redacted: user name, password, every query value, the whole fragment

    http://127.0.0.1:3080/?token=abcdef
        -> http://127.0.0.1:3080/?token=<redacted>
    https://example.com/callback?code=x&state=y#z
        -> https://example.com/callback?code=<redacted>&state=<redacted>#<redacted>
    https://user:password@example.com/path
        -> https://<redacted>@example.com/path
    ```

    It is applied to OSLog messages, to the lifecycle trace (which the
    verification scripts capture into log files), to the self-test reports and to
    the parser probe. The Objective-C++ bridge never formats a URL for a log:
    `BrowserBridge -loadURL:`'s argument is only ever handed to
    `CefFrame::LoadURL`, so the policy stays in one place. Raw address-field
    text is never traced either: the search event is
    `navigation:parsed-as-search` with no query text, and
    `NavigationInputProbe` prints sanitized URLs only.

    Redaction is an observability rule, not a navigation rule: `BrowserSession`,
    `BrowserBridge -loadURL:` and `CefFrame::LoadURL` still receive the
    original, complete URL. OSLog values are marked `.public` only once they
    have been sanitized. `URLLogSanitizerTests` pins the policy down, and
    `Scripts/verify_milestone2.sh` checks it in the shipped binary and in a real
    run's lifecycle trace.

### Troubleshooting: the "Chromium Safe Storage" keychain prompt

CEF/Chromium encrypts stored cookies and passwords through a
`Chromium Safe Storage` item in the login keychain. Because development builds
are ad-hoc signed (`CODE_SIGN_IDENTITY: "-"`), every rebuild produces a binary
with a different signature, and macOS treats the request as coming from a new
application: it shows an authorization dialog whose answer **blocks CEF's main
thread** until it is answered. While it is on screen the app cannot create its
window, the CEF message pump cannot run, and any verification run appears to
hang.

Deal with it once, in either of these ways:

- click **Always Allow** the first time the dialog appears, which adds the
  binary to the item's ACL, or
- delete the stale item so Chromium creates a fresh one:
  `security delete-generic-password -s "Chromium Safe Storage"`.

The verification scripts guard against the hang (they run the app under a hard
timeout and use their own data directory) but they cannot dismiss a system
dialog. If a run fails with everything timing out, look for that dialog first.

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

History, downloads, session restore and Liquid Glass styling — see
`ARCHITECTURE.md` milestones 5-8. Space deletion and persistence are also
outside the in-memory Milestone 4 scope. The toolbar and sidebar remain plain
until the later styling milestone.
