# NativeBrowser architecture

This document describes the checked-in implementation. Layout and native-control contracts in AGENTS.md remain authoritative. There is no staged feature specification or alternate historical design.

## Process and ownership

The macOS 26+ application uses Swift 6, SwiftUI, AppKit, Objective-C++ and CEF. Swift code never owns a CEF C++ object. XcodeGen's project.yml is the only project definition; the generated Xcode project is not tracked.

```text
BrowserMain
  -> CEFProcessHost                 framework loader, CefInitialize, external pump
  -> NativeBrowserApp              single SwiftUI Window scene and native menu
       -> ApplicationRuntime       application-scoped services and termination
            -> BrowserWorkspaceStore
                 -> WorkspaceCollection
                      -> BrowserSpace / BrowserTab / BrowserSplitLayout
                      -> durable WorkspaceSessionSnapshot
                      -> recently closed snapshots
                 -> BrowserSessionManager
                      -> tab UUID -> BrowserSession -> BrowserBridge -> CefBrowser
                      -> tab UUID -> ChromiumContainerView
                      -> stable BrowserSurfaceHostView
            -> SessionStore
            -> HistoryService -> HistoryStore (SQLite)
            -> DownloadManager
```

The app, Helper tool and standalone unit-test bundle are Xcode targets. Selected pure and native UI sources are currently compiled directly into the standalone test target. No test host starts Chromium for those unit tests.

## CEF boundary and bundle

BrowserMain executes any CEF subprocess handoff before initialization, initializes CEF before SwiftUI, and starts the native application run loop. CEFProcessHost uses CefScopedLibraryLoader: the framework is loaded at runtime, never linked directly. Only libcef_dll_wrapper.a is linked into the App and Helper.

Scripts/package_cef_runtime.sh assembles one versioned Chromium Embedded Framework.framework and five bundles in NativeBrowser.app/Contents/Frameworks:

- NativeBrowser Helper.app
- NativeBrowser Helper (Alerts).app
- NativeBrowser Helper (GPU).app
- NativeBrowser Helper (Plugin).app
- NativeBrowser Helper (Renderer).app

Helper names are derived from the main product name. Their bundle IDs derive from the main bundle ID with .helper and process suffixes. Each Helper uses LoadInHelper() to load the same framework through `../../..` relative to its executable. The packager signs nested code from the inside out; Xcode signs the outer application.

The checked-in build recipe targets arm64 and macOS 26+. Debug uses local ad-hoc signing and the existing development mock-keychain policy. Release uses hardened runtime and the checked-in JIT/library-validation entitlements. Developer ID signing, notarization and distribution assets are not implemented. ThirdParty/ is untracked binary/build input and is not a Swift package.

CEF callbacks pass through Objective-C-compatible bridge delegates. UI-facing state changes occur on the main actor. NSApplication+CefSupport implements CEF's native event-dispatch protocol without intercepting browser-shell shortcuts or replacing the application event loop.

## Domain, selection and persistence

WorkspaceCollection owns ordered Spaces, domain tab identities, membership, selected Space/tab, top pins, space pins, temporary tabs, split groups and the bounded recently-closed stack. BrowserSpace, BrowserTab, BrowserSplitLayout and snapshot values contain no CEF runtime objects.

Top pins remain visible across Spaces. Space pins belong to their Space; temporary tabs are the default destination for new tabs. Each Space keeps a stableTabStack separate from sidebar order. Opening or activating a tab moves it to the top. Closing the selected tab skips stale identities and selects the newest valid stable tab, then a temporary tab, then another remaining tab or a replacement in the same Space. Background close does not rewrite that stack.

BrowserWorkspaceStore is the mutable domain owner and owns selection transitions. BrowserSessionManager retains only instantiated sessions, their containers and typed callbacks. A closing runtime remains registered until OnBeforeClose. The application has no second liveness registry.

SessionStore writes session-v1.json under ~/Library/Application Support/NativeBrowser/, or the explicit NATIVEBROWSER_DATA_DIR override. The versioned Codable snapshot preserves exact URLs, titles, identities, ordering, selections, tiers and split state. Restore validates the graph before accepting it; malformed input falls back to the normal fresh workspace. Runtime loading state, focus, field edit buffers, CEF history and recently-closed state are not restored. Only the selected tab's runtime is created at launch; activating a lazy tab creates it once, and closing a lazy tab never creates a browser just to close it.

Session/history files use private permissions and atomic session writes. Persistence failures are local and nonfatal. Existing data is not silently migrated between product namespaces.

## Surface and UI lifetime

MainWindowView hosts the AppKit shell through NativeBrowserShellRepresentable. The application uses one Window scene because the workspace owns one set of native Chromium surfaces.

BrowserSurfaceHostView retains one BrowserPagePresentation per live session. A page retains its stable outer viewport, ChromiumContainerView and tab-bound BrowserToolbarController. Selecting tabs, changing sections or changing splits does not rebuild a Chromium view, create another browser or rebind a shared address editor. Containers are released only after their typed close callback. Presentation clipping and rounded corners belong to native outer viewports; Chromium receives rectangular rendering bounds.

BrowserWindowChromeView owns the native traffic lights and window gestures. BrowserMainViewController owns sidebar/section presentation and SpaceToolbarController. Toolbar controls mount above the shell backdrop, outside the Main View clip. Only Space displays the sidebar control and browser navigation/address controls. History, Downloads and Settings use native UI; switching sections retains the browser surface behind them.

The shell has one backgroundGlass backdrop. BrowserLayout in UI/Main/BrowserShellLayout.swift centralizes the 56 pt toolbar/rail, 4 pt equal right/bottom Main View insets and 14 pt content corners. Native traffic lights remain centered using their actual dimensions. The sidebar visible glass is 36 x 36 pt; Back and Forward occupy one continuous 72 x 36 pt interactive glass capsule in a 74 x 36 pt host. Stable native buttons and glass identities remain mounted across state changes. AGENTS.md and Animation/GLASS_COMPONENT_MOTION.md specify the full geometry and interaction contract.

## Focus and commands

BrowserSession's wantsPageFocus gates deferred creation focus and Chromium's own focus requests. A hidden or background session cannot take the keyboard merely because its browser or navigation completes. Releasing one browser only clears its own native responder; application termination explicitly releases page focus for teardown.

Each session owns an AddressFieldModel with a committed URL and independent edit buffer. Main-frame callbacks update the committed URL but do not overwrite text while editing. AddressField wraps native NSTextField, uses AppKit's shared field editor and preserves marked text. Return, Escape and field-editor commands are handled through native delegate methods; the code does not replace IME composition or implement a global keyboard monitor.

A tab selection ends the outgoing address edit, publishes the new presentation and returns focus to the incoming page. Sidebar selection explicitly requests page focus. Background metadata/URL callbacks do not mutate the active tab's buffer or selection. Pane selection and asynchronous focus delivery recheck current identity/visibility.

AppCommands installs menu key equivalents. Actions resolve the selected session when invoked:

| Shortcut | Current action |
| --- | --- |
| Cmd-L | Focus selected address field and select all |
| Cmd-R | Reload or stop selected page |
| Cmd-[ / Cmd-] | Back / Forward |
| Cmd-T | Open/toggle Spotlight for a new tab |
| Cmd-W | Close selected tab |
| Cmd-Shift-T | Reopen a fresh runtime from the latest closed snapshot |
| Cmd-1...Cmd-9 | Positional selection; Cmd-9 selects the last tab |
| Cmd-S | Toggle Space sidebar |
| Cmd-D | Move selected tab between Space pin and temporary |
| Option-Cmd-I | Toggle selected page's Web Inspector |
| Option-Cmd-U | View page source |

AppDelegate removes the competing standard window Cmd-W menu item; the red native close button still closes the window. The inspector's privileged transport is bound only to explicitly marked inspector browsers, never arbitrary page JavaScript.

## Navigation, popups, history and downloads

NavigationInput parses explicit schemes and URL-like input without modifying query/fragment identity. Other text becomes a Google search through SearchEngine. URLLogSanitizer is a single observability policy: scheme/host/port and parameter names remain; user-info, non-root path contents, query values and fragments are redacted. Navigation and private persistence receive exact URLs; no CEF URL logging bypasses the sanitizer.

CEF cancels unmanaged popups and forwards their URL to the source BrowserSession. The workspace resolves the source tab's Space (or selected Space for a top pin), inserts a managed tab after its source and selects it only when appropriate. No popup creates an unowned CEF window. Full window.opener/OAuth child-window scripting semantics are not implemented.

HistoryService records successful main-frame final URLs and titles, including visits after redirects; failed/provisional loads do not become visits. HistoryStore uses system SQLite. Downloads remain process-memory values. DownloadManager reduces names to safe components, keeps paths within the destination directory and chooses collision-safe names. Teardown cancels active CEF downloads before browser destruction. Download rows do not retain the originating BrowserSession.

Renderer termination marks that session as crashed and exposes a reload action while retaining its stable view; normal network failures remain navigation failures.

## Close and application termination

An ordinary close requests CloseBrowser(false). A native beforeunload alert can cancel without removing the domain tab or writing recently-closed state. The typed acceptance callback commits removal and completes the embedded view close. Termination is a separate force-close policy for all instantiated sessions.

```text
AppDelegate.applicationShouldTerminate
  -> start ApplicationRuntime.Terminator
  -> return terminateCancel (unwind the native event/CEF stack)
  -> default run-loop step: flush snapshot, request all live closes
  -> typed OnBeforeClose callbacks remove sessions and wake the coordinator
  -> live count reaches zero
  -> CefShutdown once
  -> retry NSApp.terminate
  -> terminateNow
```

Repeated quit requests are idempotent. Production diagnostic waits do not turn a live browser into an unsafe CefShutdown. shutdownCEF refuses while a session is live. There is no lifecycle-string control flow, forced release timer or terminateLater nested modal shutdown path. The narrowly gated deferred-close diagnostic used by the history/download self-test is not a production termination policy.

## Animation

Animation/ contains shared motion, tuning and persisted speed preferences. UI components reference named AnimationValues. Standard-pace timings are resolved once through AnimationValues.duration; curves and geometry do not scale with speed. Handoff, retention and cleanup waits share the captured flight clock. Reduce Motion and system-owned animation remain intact. CEF scheduling, input debounce and polling are operational timing.

First-level glass motion uses the native materialize transition and shared position/size Spring implementation. Interrupted flights continue from their current geometry/velocity; equal destinations do not restart them. Page and toolbar reveal share the handoff transaction. Native controls/editors stay mounted and first-level motion is not recursively applied to their symbols or text.

## Verification and compatibility

Scripts/verify_current.sh validates the current implementation by responsibility. The required app build always uses CONFIGURATION=Debug Scripts/build.sh, with DerivedData under build/. verify_unit_tests.sh runs the standalone XCTest bundle and any extracted local-package tests. Runtime, rendering, navigation, tabs, workspace, restore, history/downloads and stability checks inspect actual compiled behavior. Release verification also builds through Scripts/build.sh.

Numbered verify_milestone scripts are compatibility forwarding entry points only. Existing binary diagnostic switches and trace names are retained for tooling. Their historical output does not define the current design. The original baseline report is kept separately from current verification results.

The legacy --browser-self-test has a known nested-run-loop close limitation; it is retained unchanged and is not the rendering gate. Rendering verification uses normal app launch/page-load/typed termination. The legacy workspace driver contains three shared-address-editor focus expectations that no longer describe the tab-bound toolbar policy. check_workspace_report.py explicitly reports those as retired coverage, rejects every other failure and checks the remaining runtime invariants. Those checks are not claimed fixed or passing. Current address-field focus, IME, shortcuts, visual material outlines, split/drag motion and real Cmd-Q remain manual verification; see docs/manual-verification.md.
