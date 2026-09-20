# Native Chromium Browser for macOS — Codex Implementation Spec

> Goal: Build a macOS-only Chromium browser shell using Apple native UI, with an Arc-like sidebar layout and Apple Liquid Glass visual language.
>
> Primary stack: **SwiftUI + AppKit + Objective-C++ + CEF (Chromium Embedded Framework)**.
>
> This document is intended to be directly consumed by Codex as an implementation specification.

---

## 1. Product Goal

Build a usable macOS desktop browser with:

- Native Apple UI
- Liquid Glass visual style
- Arc-like vertical sidebar
- Chromium rendering engine via CEF
- Multiple tabs
- Spaces / tab groups
- Native keyboard shortcuts
- Navigation controls
- Basic history
- Downloads
- Session restore
- macOS-native window behavior

The browser should feel like a native macOS application instead of an Electron application.

The first milestone is **not** intended to replace Chrome completely.

---

## 2. Non-Goals for MVP

Do **not** implement these in the first version:

- Chrome Web Store extensions
- Chrome account login
- Chrome Sync
- Password manager
- Full browser profile management UI
- Ad blocker
- Arc Boost
- Vertical split view
- Tab suspension
- AI assistant
- Browser automation / agent
- Custom Chromium fork
- Off-screen rendering (OSR)
- Cross-platform support

These may be added later.

---

## 3. Target Platform

### Minimum target

- macOS 26+
- Apple Silicon first
- Xcode latest stable
- Swift latest stable
- SwiftUI + AppKit interoperability

Intel support is optional.

---

## 4. Architecture

Use the following high-level architecture:

```text
┌─────────────────────────────────────────────┐
│                SwiftUI UI                   │
│                                             │
│ Sidebar / Spaces / Tabs / Command Bar       │
│ Settings / History / Downloads              │
└──────────────────────┬──────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────┐
│                 AppKit                      │
│                                             │
│ NSWindow / NSView / focus / keyboard        │
│ browser container / native event handling   │
└──────────────────────┬──────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────┐
│          Objective-C++ Bridge               │
│                                             │
│ BrowserBridge.mm                            │
│ CEF lifecycle adapter                       │
└──────────────────────┬──────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────┐
│                   CEF                       │
│                                             │
│ Chromium / Blink / V8 / Network / GPU       │
└─────────────────────────────────────────────┘
```

### Key architecture rule

Swift code must **not** directly own or expose CEF C++ objects.

Do not expose these types into Swift:

```cpp
CefBrowser
CefClient
CefFrame
CefRequest
CefBrowserHost
```

All CEF access must go through an Objective-C compatible abstraction layer.

---

## 5. Recommended Project Structure

Use a structure similar to:

```text
NativeBrowser/
├── App/
│   ├── NativeBrowserApp.swift
│   ├── AppDelegate.swift
│   └── AppEnvironment.swift
│
├── Domain/
│   ├── Models/
│   │   ├── BrowserTab.swift
│   │   ├── BrowserSpace.swift
│   │   ├── NavigationState.swift
│   │   └── DownloadItem.swift
│   │
│   ├── Services/
│   │   ├── TabService.swift
│   │   ├── SpaceService.swift
│   │   ├── HistoryService.swift
│   │   └── SessionService.swift
│
├── Browser/
│   ├── BrowserController.swift
│   ├── BrowserSession.swift
│   ├── ChromiumView.swift
│   ├── ChromiumContainerView.swift
│   └── BrowserEvent.swift
│
├── Bridge/
│   ├── BrowserBridge.h
│   ├── BrowserBridge.mm
│   ├── CEFAppDelegate.h
│   ├── CEFAppDelegate.mm
│   ├── CEFClientHandler.h
│   └── CEFClientHandler.mm
│
├── UI/
│   ├── Main/
│   │   ├── MainWindowView.swift
│   │   └── BrowserContentView.swift
│   │
│   ├── Sidebar/
│   │   ├── SidebarView.swift
│   │   ├── TabRowView.swift
│   │   └── SpaceSwitcherView.swift
│   │
│   ├── CommandBar/
│   │   ├── CommandBarView.swift
│   │   └── AddressField.swift
│   │
│   ├── History/
│   ├── Downloads/
│   └── Settings/
│
├── Persistence/
│   ├── PersistenceController.swift
│   ├── HistoryStore.swift
│   └── SessionStore.swift
│
├── Resources/
│
└── Frameworks/
    └── Chromium Embedded Framework.framework
```

The exact file names may differ, but keep these responsibilities separate.

---

## 6. Domain Model

CEF browser instances must not be the application domain model.

Define an independent tab model.

Example:

```swift
struct BrowserTab: Identifiable, Codable, Equatable {
    let id: UUID

    var title: String
    var url: URL?
    var faviconURL: URL?

    var isLoading: Bool
    var loadingProgress: Double

    var canGoBack: Bool
    var canGoForward: Bool

    var createdAt: Date
    var lastActivatedAt: Date
}
```

Space model:

```swift
struct BrowserSpace: Identifiable, Codable, Equatable {
    let id: UUID

    var name: String
    var tabIDs: [UUID]
    var selectedTabID: UUID?
}
```

Runtime CEF objects belong in a separate layer:

```text
BrowserTab
    │
    ▼
BrowserSession
    │
    ▼
CEF Browser
```

`BrowserSession` is runtime-only and should not be Codable.

---

## 7. Browser Session Model

Create one runtime browser session for each active Chromium tab.

Example interface:

```swift
final class BrowserSession: ObservableObject {
    let tabID: UUID

    @Published private(set) var url: URL?
    @Published private(set) var title: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var loadingProgress: Double = 0

    func attach(to view: NSView)

    func load(_ url: URL)

    func goBack()
    func goForward()
    func reload()
    func stop()

    func focus()
    func blur()

    func close()
}
```

The actual implementation may internally delegate to `BrowserBridge`.

---

## 8. Swift / Objective-C++ Bridge

Implement a narrow Objective-C compatible interface.

Example:

```objc
typedef NS_ENUM(NSInteger, BrowserNavigationEventType) {
    BrowserNavigationEventTypeDidStart,
    BrowserNavigationEventTypeDidFinish,
    BrowserNavigationEventTypeDidFail
};

@protocol BrowserBridgeDelegate <NSObject>

- (void)browserDidUpdateTitle:(NSString *)title;
- (void)browserDidUpdateURL:(NSString *)url;

- (void)browserDidUpdateLoadingState:(BOOL)isLoading
                          canGoBack:(BOOL)canGoBack
                       canGoForward:(BOOL)canGoForward;

- (void)browserDidUpdateLoadingProgress:(double)progress;

@end

@interface BrowserBridge : NSObject

@property(nonatomic, weak) id<BrowserBridgeDelegate> delegate;

- (instancetype)initWithParentView:(NSView *)view;

- (void)loadURL:(NSString *)url;

- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stop;

- (void)setFocus:(BOOL)focused;

- (void)resizeToBounds:(NSRect)bounds;

- (void)close;

@end
```

Implementation lives in:

```text
BrowserBridge.mm
```

and owns CEF C++ types.

### Bridge rules

1. Swift must not import CEF headers.
2. CEF callbacks should be transformed into Objective-C delegate events.
3. UI-facing state updates must return to the main thread.
4. Avoid exposing raw pointers.
5. Closing a tab must correctly release the corresponding CEF browser.

---

## 9. CEF Integration Strategy

Use **native windowed rendering**, not OSR.

Expected hierarchy:

```text
SwiftUI
  ↓
NSViewRepresentable
  ↓
NSView
  ↓
CEF browser view
```

Example SwiftUI wrapper:

```swift
struct ChromiumView: NSViewRepresentable {

    let session: BrowserSession

    func makeNSView(context: Context) -> ChromiumContainerView {
        let view = ChromiumContainerView()
        session.attach(to: view)
        return view
    }

    func updateNSView(
        _ nsView: ChromiumContainerView,
        context: Context
    ) {
        session.attach(to: nsView)
    }
}
```

The container must react correctly to resize.

Prefer AppKit autoresizing or explicit resize callbacks rather than excessive SwiftUI layout hacks.

---

## 10. CEF Process Model

Expect Chromium to use helper processes including:

- Renderer
- GPU
- Network-related processes
- Utility processes

The final `.app` bundle must contain the CEF framework and helper apps in the layout required by CEF.

Account for:

```text
NativeBrowser.app
Contents/
├── MacOS/
│   └── NativeBrowser
│
└── Frameworks/
    ├── Chromium Embedded Framework.framework
    ├── NativeBrowser Helper.app
    ├── NativeBrowser Helper (GPU).app
    ├── NativeBrowser Helper (Renderer).app
    └── NativeBrowser Helper (Plugin).app
```

Exact helper requirements depend on the CEF build used.

Do not hard-code assumptions that prevent future CEF upgrades.

---

## 11. CEF Lifecycle

Implement application initialization early in process startup.

High-level startup sequence:

```text
Process starts
    │
    ├── detect CEF subprocess
    │
    ├── execute CEF subprocess entry if needed
    │
    └── otherwise continue main app
            │
            ▼
        initialize CEF
            │
            ▼
        initialize SwiftUI application
```

Shutdown sequence:

```text
SwiftUI app termination
    │
    ▼
close browser instances
    │
    ▼
wait for browser shutdown
    │
    ▼
shutdown CEF
```

Shutdown correctness is important.

Avoid crashes caused by terminating the process while Chromium objects still exist.

---

## 12. Main Window Layout

Target layout:

```text
┌────────────────────────────────────────────────┐
│                                                │
│ ┌───────────────┐ ┌──────────────────────────┐ │
│ │               │ │                          │ │
│ │   Sidebar     │ │       Chromium           │ │
│ │               │ │                          │ │
│ │   Space A     │ │                          │ │
│ │    Tab 1      │ │                          │ │
│ │    Tab 2      │ │                          │ │
│ │               │ │                          │ │
│ │   Space B     │ │                          │ │
│ │               │ │                          │ │
│ └───────────────┘ └──────────────────────────┘ │
│                                                │
└────────────────────────────────────────────────┘
```

Recommended initial dimensions:

```text
Window width: 1280
Window height: 800

Sidebar:
  min: 220
  default: 260
  max: 360
```

Allow the sidebar to collapse later, but it is not required for the first milestone.

---

## 13. Liquid Glass UI

Use Apple native visual APIs.

Do not manually reproduce the appearance using custom blur stacks if the system API provides the desired result.

Use Liquid Glass for:

- sidebar
- command bar
- floating controls
- compact overlays

Do **not** apply heavy glass effects directly over the browser rendering surface.

Concept:

```text
ZStack
├── Chromium content
└── Native UI chrome
    ├── glass sidebar
    ├── floating command bar
    └── contextual controls
```

Example:

```swift
VStack {
    sidebarContent
}
.padding(8)
.glassEffect(
    .regular,
    in: RoundedRectangle(
        cornerRadius: 20,
        style: .continuous
    )
)
```

Use `GlassEffectContainer` where grouping multiple glass controls improves visual behavior.

---

## 14. Sidebar

Sidebar responsibilities:

- show current space
- display tab list
- select tab
- add tab
- close tab
- rename space
- switch spaces

Suggested design:

```text
[ Space selector ]

Pinned / regular tabs

  Google
  GitHub
  ChatGPT
  Reddit

[ + New Tab ]

-----------------

Downloads
History
Settings
```

Each tab row should show:

- favicon
- title
- loading indicator if needed
- close button on hover

Avoid implementing complex pinning behavior in MVP unless straightforward.

---

## 15. Command Bar

The command bar combines:

- URL entry
- search query entry
- command launcher

First version only needs URL/search behavior.

Shortcut:

```text
⌘L
```

Behavior:

1. Focus command bar.
2. Select existing contents.
3. User types text.
4. If valid URL-like input, navigate directly.
5. Otherwise, use configured search engine.

Default search URL:

```text
https://www.google.com/search?q=<query>
```

Keep search-engine resolution isolated behind:

```swift
protocol SearchEngine {
    func searchURL(for query: String) -> URL
}
```

---

## 16. Input Parsing

Create:

```swift
enum NavigationInput {
    case url(URL)
    case search(String)
}
```

Provide:

```swift
func parseNavigationInput(_ input: String) -> NavigationInput
```

Rules:

Treat these as URLs:

```text
https://example.com
http://example.com
localhost:8080
example.com
192.168.1.10
```

Treat normal text as search query.

Do not over-engineer URL parsing.

---

## 17. Keyboard Shortcuts

Implement at minimum:

```text
⌘L    Focus address bar

⌘T    New tab

⌘W    Close current tab

⌘R    Reload

⌘[    Back

⌘]    Forward

⌘1-9  Select tab by position if convenient

⌘Shift+T
      Restore recently closed tab
```

Keyboard handling should remain reliable while Chromium owns focus.

If SwiftUI shortcut handling becomes unreliable, implement command handling through AppKit:

- `NSResponder`
- `NSMenuItem`
- application command routing

Do not let Chromium swallow browser-shell shortcuts that belong to the application.

---

## 18. Focus Management

Focus handling is a critical requirement.

There are three focus systems:

```text
SwiftUI FocusState
AppKit firstResponder
CEF / Chromium focus
```

Required behaviors:

### Browser focus

When user clicks page content:

```text
NSWindow firstResponder
    ↓
CEF browser view
```

### Address bar focus

When user presses `⌘L`:

```text
CEF loses keyboard focus
    ↓
address field becomes first responder
```

### Returning to browser

On Enter after navigation:

```text
address field resigns focus
    ↓
CEF browser receives focus
```

Test with:

- English keyboard
- Chinese IME
- contenteditable
- text inputs
- keyboard navigation
- switching tabs

---

## 19. Chinese IME

Chinese input must work in:

- address bar
- web text fields
- contenteditable pages

Validate:

- candidate popup placement
- composition state
- Enter selection
- Escape cancellation
- switching between command bar and page

Do not ship an implementation that works only for ASCII keyboard input.

---

## 20. Navigation State

CEF callbacks should update:

```swift
struct NavigationState {
    var url: URL?
    var title: String

    var isLoading: Bool
    var progress: Double

    var canGoBack: Bool
    var canGoForward: Bool
}
```

UI must react to this state.

Examples:

- disable Back when `canGoBack == false`
- disable Forward when `canGoForward == false`
- show reload vs stop depending on loading state
- display page title in sidebar

---

## 21. New Windows and Popups

Handle:

```javascript
window.open(...)
```

and target:

```html
<a target="_blank">
```

Default policy:

### Normal web popup

Open as a new browser tab.

### OAuth / payment popup

For the first version, either:

- create a separate native browser window, or
- open in a tab

Prefer correctness over mimicking Arc exactly.

Do not silently block popups required for login flows.

Create a policy abstraction:

```swift
enum PopupDisposition {
    case newTab
    case newWindow
    case block
}
```

---

## 22. Downloads

Minimum download manager functionality:

- detect download start
- ask CEF to save into Downloads directory
- show active download
- show progress
- show completed state
- open downloaded file in Finder

Model:

```swift
struct DownloadItem: Identifiable {
    let id: UUID

    var fileName: String
    var sourceURL: URL
    var destinationURL: URL?

    var receivedBytes: Int64
    var totalBytes: Int64?

    var state: DownloadState
}
```

States:

```swift
enum DownloadState {
    case pending
    case downloading
    case completed
    case failed
    case cancelled
}
```

---

## 23. History

Store basic browsing history.

Record:

```text
URL
title
timestamp
visit count
```

Suggested model:

```swift
struct HistoryEntry: Identifiable, Codable {
    let id: UUID
    let url: URL
    var title: String
    var visitCount: Int
    var lastVisitedAt: Date
}
```

Persistence options:

Preferred:

```text
SQLite
```

Acceptable for MVP:

```text
SwiftData
```

Do not store full page content.

---

## 24. Session Restore

On application exit, persist:

```text
spaces
tab order
selected space
selected tab
tab URLs
```

Do not persist live Chromium objects.

Persist only domain state.

Example JSON-like state:

```json
{
  "spaces": [
    {
      "name": "Main",
      "selectedTabID": "...",
      "tabs": [
        {
          "url": "https://github.com",
          "title": "GitHub"
        }
      ]
    }
  ]
}
```

On startup:

1. restore domain model
2. create selected tab first
3. lazily create other tab browser sessions

Avoid initializing dozens of Chromium instances at startup.

---

## 25. Lazy Tab Instantiation

Do not create every CEF browser immediately.

Recommended behavior:

```text
Restored tab model
    │
    ├── selected tab
    │      └── create BrowserSession now
    │
    └── background tab
           └── create BrowserSession on first activation
```

Benefits:

- lower startup latency
- lower RAM usage
- fewer Chromium renderer processes

---

## 26. Tab Closing

Closing a tab must:

1. update domain model
2. detach CEF browser view
3. request Chromium browser close
4. release browser session
5. select adjacent tab if needed

Do not merely hide the NSView.

Verify with repeated creation / closing of tabs and watch memory usage.

---

## 27. Multi-Space Behavior

A Space is a logical tab group.

Example:

```text
Space: Work
├── GitHub
├── Linear
└── ChatGPT

Space: Personal
├── YouTube
└── Reddit
```

Switching spaces should switch the visible selected tab.

Do not destroy Chromium sessions simply because a Space becomes inactive.

Future optimization can add tab suspension.

---

## 28. Browser View Visibility

Only one browser view per window is normally visible.

Recommended:

```text
active tab session
    ↓
attach / show browser NSView

inactive sessions
    ↓
hidden or detached depending on CEF behavior
```

Choose the approach that does not accidentally recreate browser instances.

Do not rebuild the entire Chromium NSView on every SwiftUI render.

---

## 29. SwiftUI State Management

Avoid putting browser lifecycle directly inside SwiftUI Views.

Recommended:

```text
MainWindowView
    ↓
BrowserWorkspaceStore
    ├── SpaceService
    ├── TabService
    ├── SessionManager
    ├── HistoryService
    └── DownloadService
```

Possible top-level store:

```swift
@MainActor
final class BrowserWorkspaceStore: ObservableObject {

    @Published var spaces: [BrowserSpace] = []
    @Published var selectedSpaceID: UUID?

    let sessionManager: BrowserSessionManager

    func createTab()
    func closeTab(_ id: UUID)
    func selectTab(_ id: UUID)
}
```

Keep side effects in services/controllers rather than views.

---

## 30. Threading Rules

CEF callbacks may arrive from CEF-managed threads.

All SwiftUI-observed state mutations must happen on the main actor.

Example:

```swift
DispatchQueue.main.async {
    self.title = title
}
```

or bridge into an `@MainActor` object.

Do not accidentally access AppKit views from arbitrary CEF threads.

---

## 31. Error Handling

Display a native error state if navigation fails.

Example error page can show:

```text
Unable to load page

ERR_CONNECTION_REFUSED

[ Retry ]
```

Do not crash for normal network errors.

Capture at least:

- DNS failures
- connection refused
- TLS failures
- invalid URLs
- renderer crashes if exposed through CEF callbacks

---

## 32. DevTools

For development builds, support opening Chromium DevTools.

Shortcut suggestion:

```text
⌥⌘I
```

Allow:

```text
browser.showDevTools()
```

Do not expose internal bridge code into page JavaScript.

Remote debugging may be enabled in Debug configuration only.

---

## 33. Security Rules

MVP must still respect baseline browser safety.

Do not:

- disable TLS verification globally
- disable Chromium sandbox without a clear development-only reason
- inject arbitrary native bridge APIs into every webpage
- enable unrestricted remote debugging in production
- expose filesystem APIs to page JS

If local browser-agent functionality is added later, isolate it behind explicit permissions.

---

## 34. Code Signing / Distribution

Design the application so that:

```text
Main app
CEF framework
CEF helper apps
```

can all be correctly signed.

Production requirements eventually include:

- Hardened Runtime
- code signing
- notarization
- correct helper entitlements
- stable bundle identifiers

Suggested identifiers:

```text
com.example.NativeBrowser
com.example.NativeBrowser.helper
com.example.NativeBrowser.helper.renderer
com.example.NativeBrowser.helper.gpu
```

Exact identifiers should be configured in project settings.

Do not block MVP implementation on public distribution, but do not design the bundle in a way that makes signing impossible.

---

## 35. Logging

Add structured logging for:

```text
app lifecycle
CEF init / shutdown
browser creation
browser destruction
navigation
tab creation / close
popup
download
renderer termination
fatal bridge errors
```

Use Apple unified logging:

```swift
import OSLog
```

Example categories:

```text
app
cef
browser
navigation
download
session
```

Avoid `print()` as the primary observability mechanism.

### URL redaction

Never write a browser URL to a log or a trace verbatim. A URL can carry a
session token (`?token=...`), an OAuth code, a signature, or credentials in its
user-info or fragment, and the lifecycle trace is written to standard output and
captured into log files by the verification scripts.

One helper owns the policy: `URLLogSanitizer`
(`NativeBrowser/App/URLLogSanitizer.swift`).

```text
kept:     scheme, host, port, path, query parameter names
redacted: user name, password, every query value, the whole fragment

http://127.0.0.1:3080/?token=abcdef
    -> http://127.0.0.1:3080/?token=<redacted>
https://example.com/callback?code=secret&state=abc#private
    -> https://example.com/callback?code=<redacted>&state=<redacted>#<redacted>
https://user:password@example.com/path
    -> https://<redacted>@example.com/path
```

Rules that go with it:

- Raw address-field text is never logged or traced. A search query is as
  sensitive as a URL, so the event is `navigation:parsed-as-search` with no
  query text, and the parser probe prints sanitized URLs only.
- OSLog `.public` is used only for values that have already been sanitized; it
  is never used to publish a complete URL.
- Redaction is an observability rule, not a navigation rule. `BrowserSession`,
  `BrowserBridge -loadURL:`, `CefFrame::LoadURL` and the address/search parser
  all receive the original, complete URL.
- Error logs keep the error code, the error text and a sanitized URL.

---

## 36. Performance Metrics

Capture basic metrics:

```text
app launch time
time to first browser view
time to first page navigation
tab creation latency
memory after 1 tab
memory after 10 tabs
```

MVP does not need telemetry upload.

Local logging is enough.

---

## 37. Testing Strategy

### Unit Tests

Test:

- navigation input parsing
- tab ordering
- space switching
- session serialization
- session restore
- history storage
- recently closed tabs

### Integration Tests

Test:

- CEF initializes
- page loads
- title changes
- URL changes
- back/forward
- reload
- tab close
- popup
- download
- app termination

### Manual Tests

Test at minimum:

```text
https://google.com
https://github.com
https://youtube.com
https://chatgpt.com
```

Also test:

- localhost
- invalid domains
- offline mode
- large pages
- WebGL page
- HTML5 video
- login popup
- file download
- Chinese IME

---

## 38. MVP Milestones

Implement in this order.

---

### Milestone 0 — Project Bootstrapping

Deliverables:

- macOS SwiftUI app launches
- AppDelegate available
- AppKit interoperability works
- CEF framework integrated into build
- helper process targets configured

Acceptance:

```text
App launches without Chromium browser view.
CEF can initialize and shutdown cleanly.
```

---

### Milestone 1 — One Chromium Tab

Deliverables:

- one `ChromiumView`
- load hard-coded URL
- resize with window
- navigation callbacks
- title callback
- URL callback

Acceptance:

```text
Open app
→ google.com renders
→ resize works
→ typing/clicking works
→ closing app does not crash
```

---

### Milestone 2 — Navigation UI

Deliverables:

- Back
- Forward
- Reload
- Stop
- address bar
- `⌘L`

Acceptance:

```text
Navigate to multiple URLs.
Back/forward state is correct.
Address field updates after page navigation.
```

---

### Milestone 3 — Tabs

Deliverables:

- browser domain tab model
- multiple `BrowserSession`s
- sidebar tab list
- create tab
- close tab
- select tab
- `⌘T`
- `⌘W`

Acceptance:

```text
Open 10 tabs.
Switch repeatedly.
Close repeatedly.
No crashes.
No obvious browser-session leaks.
```

---

### Milestone 4 — Spaces

Deliverables:

- create default Space
- multiple Spaces
- switch Space
- tabs belong to Space

Acceptance:

```text
Tabs remain associated with their Space.
Switching Spaces updates selected browser correctly.
```

---

### Milestone 5 — Liquid Glass UI

Deliverables:

- native Liquid Glass sidebar
- native floating address bar or toolbar treatment
- polished spacing
- native window styling

Acceptance:

```text
UI follows modern Apple macOS visual conventions.
No custom fake-glass rendering unless required.
Browser content remains performant.
```

---

### Milestone 6 — Session Restore

Deliverables:

- persist tabs
- persist Spaces
- persist selected state
- restore on launch
- lazy initialize background tabs

Acceptance:

```text
Open 10 tabs.
Quit app.
Reopen.
Workspace returns.
Only active browser session initializes immediately.
```

---

### Milestone 7 — History + Downloads

Deliverables:

- history store
- history UI
- download callback
- download list
- Finder reveal

Acceptance:

```text
Visited pages appear in history.
Normal file download completes successfully.
```

---

### Milestone 8 — Stability Pass

Focus on:

- CEF lifecycle
- app quit
- repeated tab creation
- keyboard focus
- IME
- popups
- renderer crashes
- memory

Acceptance:

```text
30+ minute browsing session
20+ tab create/close cycles
multiple videos/pages
Chinese IME works
no known deterministic crash
```

---

## 39. Acceptance Criteria for MVP

The MVP is complete only when all of the following work:

- [ ] Native macOS application
- [ ] Chromium via CEF
- [ ] Web page rendering
- [ ] Browser resizing
- [ ] URL navigation
- [ ] Google search fallback
- [ ] Back
- [ ] Forward
- [ ] Reload
- [ ] Stop loading
- [ ] Multiple tabs
- [ ] Sidebar tab UI
- [ ] Multiple Spaces
- [ ] `⌘L`
- [ ] `⌘T`
- [ ] `⌘W`
- [ ] `⌘R`
- [ ] Browser focus handling
- [ ] Chinese IME
- [ ] Page title update
- [ ] URL state update
- [ ] Popup handling
- [ ] Downloads
- [ ] History
- [ ] Session restore
- [ ] Lazy creation of restored background tabs
- [ ] DevTools in development build
- [ ] Clean app shutdown
- [ ] CEF helper processes included correctly
- [ ] App can be signed in principle
- [ ] No deterministic crash during normal browsing

---

## 40. Important Engineering Constraints

Codex must obey these constraints.

### Constraint 1

Do not replace CEF with WKWebView.

The product requirement is Chromium.

### Constraint 2

Do not replace native UI with Electron.

The shell must remain SwiftUI/AppKit.

### Constraint 3

Do not fork Chromium.

Use CEF binary distribution unless a later requirement explicitly requires custom Chromium changes.

### Constraint 4

Do not implement OSR in MVP.

Use native windowed CEF rendering.

### Constraint 5

Do not let SwiftUI directly own C++ Chromium types.

Use Objective-C++ bridge.

### Constraint 6

Do not couple persisted tab state to CEF browser instances.

Persistence uses domain models only.

### Constraint 7

Do not eagerly instantiate all restored tabs.

Background restored tabs must support lazy browser-session creation.

### Constraint 8

Do not put CEF lifecycle logic inside individual SwiftUI views.

CEF initialization/shutdown must be application-scoped.

---

## 41. Suggested Core Interfaces

### BrowserSessionManager

```swift
@MainActor
protocol BrowserSessionManaging {

    func session(for tabID: UUID) -> BrowserSession?

    func createSession(
        for tabID: UUID,
        initialURL: URL?
    ) -> BrowserSession

    func closeSession(for tabID: UUID)
}
```

### Tab service

```swift
@MainActor
protocol TabManaging {

    var tabs: [BrowserTab] { get }

    func createTab(
        in spaceID: UUID,
        url: URL?
    ) -> BrowserTab

    func closeTab(_ id: UUID)

    func selectTab(_ id: UUID)
}
```

### Session persistence

```swift
protocol WorkspacePersisting {

    func load() throws -> WorkspaceSnapshot?

    func save(_ snapshot: WorkspaceSnapshot) throws
}
```

### History

```swift
protocol HistoryManaging {

    func recordVisit(
        url: URL,
        title: String
    ) async throws

    func recentEntries(
        limit: Int
    ) async throws -> [HistoryEntry]
}
```

---

## 42. Recently Closed Tabs

Maintain an in-memory or persisted stack:

```swift
struct ClosedTabSnapshot {
    let url: URL?
    let title: String
    let spaceID: UUID
}
```

Shortcut:

```text
⌘Shift+T
```

Restores the most recently closed tab.

CEF navigation history restoration is not required in MVP.

---

## 43. Browser Crash Recovery

If a renderer terminates unexpectedly:

- do not crash the entire application
- mark affected tab as crashed
- show reload option

Example:

```text
This page stopped responding.

[ Reload ]
```

Log renderer termination reason when available.

---

## 44. UI Style Guidelines

Design principles:

- native macOS spacing
- subtle animation
- avoid excessive borders
- sidebar-first navigation
- support dark and light appearance
- Liquid Glass only where semantically appropriate
- browser content gets maximum visual priority
- controls should not constantly obscure page content

Suggested corner radius:

```text
sidebar container: 18–24
floating command bar: capsule or 16–20
tab rows: 8–12
```

Do not hard-code colors that break system appearance.

Prefer semantic colors.

---

## 45. Future Architecture Extensions

Do not implement now, but preserve room for:

### Tab suspension

```text
BrowserTab
    ↓
BrowserSession
    ↓
SuspendedSessionSnapshot
```

Possible suspension policy:

```text
inactive for N minutes
AND
not playing audio
AND
not pinned
AND
not downloading
```

---

### Browser Agent

Future architecture:

```text
BrowserSession
    │
    ├── DOM / page extraction
    ├── screenshot
    ├── CDP
    └── AgentController
```

Potential actions:

```text
navigate
read page
query DOM
click
type
scroll
extract structured data
```

Do not expose this in MVP.

---

### Semantic History

Possible future flow:

```text
Visited page
    ↓
text extraction
    ↓
embedding
    ↓
local vector index
```

This can support:

```text
"找我上周看过的 Redis 那篇文章"
```

Do not implement now.

---

## 46. Recommended Codex Working Method

Codex should proceed incrementally.

For each milestone:

1. inspect current project state
2. make smallest coherent implementation
3. build project
4. fix compile errors
5. run tests if present
6. verify architecture constraints
7. summarize changes

Do not attempt to implement the entire browser in one patch.

Do not introduce speculative abstractions unless they serve the current milestone or a clearly defined upcoming milestone.

---

## 47. First Codex Task

Start with:

> Implement Milestone 0 and Milestone 1 only.

Expected result:

```text
macOS application
    +
CEF initialized
    +
single Chromium browser view
    +
https://www.google.com loads
    +
view resizes with window
    +
clean shutdown
```

Do not build tabs, history, downloads, or Spaces yet.

Once Milestone 1 is stable, proceed to Milestone 2.

---

## 48. Definition of Done for Every Milestone

Before considering a milestone complete:

- code compiles
- application launches
- no obvious runtime crash
- relevant feature manually works
- no TODO replacing core behavior
- no architecture constraint violated
- lifecycle cleanup exists
- logging exists for new lifecycle-sensitive paths

---

## 49. Engineering Priorities

When tradeoffs arise, prioritize in this order:

```text
1. Correct CEF lifecycle
2. Browser stability
3. Input/focus correctness
4. Native macOS behavior
5. Performance
6. Architecture clarity
7. Visual polish
8. Extra features
```

Do not sacrifice browser lifecycle correctness for animations or UI polish.

---

## 50. Final Technical Direction

The implementation should converge on:

```text
SwiftUI
    │
    │ app state / Liquid Glass / sidebar / toolbar
    ▼
AppKit
    │
    │ window / responder chain / NSView container
    ▼
Objective-C++
    │
    │ safe boundary
    ▼
CEF
    │
    ▼
Chromium
```

This boundary is intentional.

The product should look and behave like a native macOS application while Chromium remains an embedded rendering engine behind a narrow bridge.

---

# Codex Bootstrap Prompt

Use the following prompt together with this document:

```text
Read ARCHITECTURE.md completely before modifying the repository.

We are building a macOS-only native Chromium browser.

The required architecture is:

SwiftUI + AppKit + Objective-C++ + CEF.

Do not use Electron.
Do not replace Chromium with WKWebView.
Do not fork Chromium.
Do not use CEF OSR for the MVP.
Do not expose CEF C++ types directly to Swift.

Work milestone by milestone.

Begin with Milestone 0 and Milestone 1 from ARCHITECTURE.md.

Before changing code:
1. inspect the repository,
2. identify the existing macOS project structure,
3. propose the minimum changes needed for the current milestone.

Then implement the changes, build the project, fix compile errors, and report:
- files changed,
- architecture decisions,
- remaining blockers,
- exact manual verification steps.

Do not proceed to the next milestone until the current milestone builds and its acceptance criteria are satisfied.
```


---

# Milestone 3 Implementation — Multiple Tabs

> Status: implemented and verified (`Scripts/verify_milestone3.sh`).
>
> This section documents what the repository **actually does** after Milestone 3.
> Where the specification above and the implementation disagree, this section is
> the description of record.

## 51. Ownership graph

```text
ApplicationRuntime                         (process-scoped, @MainActor)
  |
  +-- BrowserWorkspaceStore                (one in-memory domain owner)
  |     |
  |     +-- WorkspaceCollection            (Spaces, tabs, selection, close policy)
  |     +-- BrowserSpace -> ordered BrowserTab identities
  |     +-- recentlyClosed [ClosedTabSnapshot]
  |
  +-- BrowserSessionManager                (one runtime owner)
        |
        +-- BrowserTab A  ---> BrowserSession A ---> BrowserBridge A ---> CefBrowser A
        +-- BrowserTab B  ---> BrowserSession B ---> BrowserBridge B ---> CefBrowser B
        +-- BrowserTab C  ---> BrowserSession C ---> BrowserBridge C ---> CefBrowser C
        |
        +-- [TabID: ChromiumContainerView] (one AppKit container per *live* session)
        |
        +-- BrowserSurfaceHostView         (weak; owned by SwiftUI, one per window)
```

There is no "current CefBrowser" anywhere. Every callback travels
`CefClientHandler -> its BrowserBridge -> its BrowserSession -> its tabID`, so a
background tab's navigation can only ever update that tab.

There is also no second liveness registry. `ApplicationRuntime.hasLiveBrowsers`
asks the manager; the manager is what owns the sessions.

## 52. The tab model

`BrowserTab` (`NativeBrowser/Browser/BrowserTab.swift`) is the domain identity: a
UUID plus the metadata the sidebar shows (title, URL, loading flag, timestamps).
It contains no CEF type, no `BrowserBridge` and no `BrowserSession`, and it
imports only Foundation.

`ClosedTabSnapshot` carries a URL, a title, the index the tab occupied and a
timestamp. It deliberately carries **no** tab identifier, so reopening can only
ever produce a new `BrowserTab` with a new identity - resurrecting a closed
runtime is not expressible.

`WorkspaceCollection` (`NativeBrowser/Browser/WorkspaceCollection.swift`) is the
whole Space/tab *policy*, also Foundation-only:

- create / rename / select Spaces, append / insert-at-index / select tabs,
- one selected tab per Space and a derived effective selected tab,
- the selection rule for a close (right neighbour, else left neighbour, else a
  replacement in the same Space),
- the recently-closed stack, bounded to `recentlyClosedLimit = 10` entries and
  in memory only,
- `close(_:reason:)`, where `WorkspaceTabCloseReason` separates an ordinary
  user close from a termination close, and snapshots include `spaceID` and the
  original index.

Because it is pure, all of those rules are unit-tested in a bundle that never
links CEF (`NativeBrowser/Tests/WorkspaceCollectionTests.swift`). It is compiled
into both the application target and the test target; see `project.yml`.

## 53. Visible tabs, live sessions and closing sessions

Three sets, deliberately distinct:

| set | meaning | where |
| --- | --- | --- |
| visible tabs | what the selected Space sidebar shows | `WorkspaceCollection.tabs(in:)` |
| live sessions | every Chromium runtime the application still owns | `BrowserSessionManager.sessions` |
| closing sessions | live sessions whose tab has already left the sidebar | `closingTabIDs` |

`closingTabIDs` is an ordered array rather than a set so the closing set is
deterministic. A tab is marked closing **before** `CloseBrowser` is called and
removed from the set only in the typed close callback.

`liveSessionOrder` is the runtime registration order plus `closingTabIDs`,
deduplicated - it is the order used for the surface and for `liveSessions`.

Closing a tab and destroying its Chromium runtime are two different instants:

```text
user closes tab
  -> WorkspaceCollection records a snapshot (user close only)
  -> tab leaves its Space's visible order; a neighbour is selected, or a
     replacement tab is created in that same Space when it was the last one,
     and the keyboard follows the new selection when the closed page had it
     (section 56)
  -> the session is marked closing (it stays in `sessions`)
  -> BrowserSession.close(terminating:) -> BrowserBridge
       -> CefBrowserHost::CloseBrowser(force_close = true)
  -> CefLifeSpanHandler::DoClose -> BrowserBridge -completeClose (releases the view)
  -> CefLifeSpanHandler::OnBeforeClose -> BrowserSession.browserBridgeDidClose
  -> BrowserSession.onClosed(self)                       <-- typed, carries identity
  -> BrowserSessionManager.sessionDidClose(_:)
       -> the session is released and its container removed
       -> onLiveSessionDidClose?(session)                <-- typed, termination wakes on this
```

No step in that chain waits, sleeps or times out. Nothing inspects a lifecycle
string: `ApplicationRuntime.record(_:)` only appends to the trace.

## 54. Browser surface lifetime

`BrowserSurfaceHostView` (`NativeBrowser/Browser/BrowserSurfaceHostView.swift`) is
a single AppKit view that holds **every** live session's
`ChromiumContainerView` as a subview for as long as the session is alive. The
manager owns the containers and hands the current set in; the host only lays them
out. Selecting a tab calls `ChromiumContainerView.setSurfaceVisible(_:)`, which
sets `isHidden`.

Consequences:

- The naive `if tab.id == selectedTabID { ChromiumView(session:) }` shape does not
  exist in the codebase. The per-window `ChromiumView` representable was removed;
  `BrowserSurfaceView` is the only representable and it is created once per
  window.
- An inactive container keeps its Chromium view, so **switching tabs cannot
  create or destroy a `CefBrowser`**. `BrowserSession.browserCreationCount`
  remains `1` across selection, sidebar churn, toolbar updates, title/URL/loading
  callbacks, focus changes and window resizing - asserted by
  `--spaces-self-test` (with `--tabs-self-test` retained as a compatibility
  alias) and checked structurally by the milestone verifiers.
- A container is removed only from `sessionDidClose`, i.e. after OnBeforeClose.
- Hidden tabs are hidden, not suspended: no sleeping, freezing, discarding or
  renderer suspension (Milestone 3 section 34).

## 55. Toolbar and address field binding

One window, one sidebar, one toolbar, one address field. `MainWindowView` binds
`BrowserToolbarView(session:)` to `workspace.selectedSession`, so a selection change
re-points the toolbar, the address model, Back/Forward state and loading state
together.

Background isolation is structural rather than defensive: each `BrowserSession`
owns its own `AddressFieldModel`, and `AddressFieldModel.applyBrowserURL` only
mirrors the committed URL while `isEditing` is false. A background tab's URL
callback therefore writes to a model that is not on screen and cannot move the
selected tab's edit buffer.

The ⌘L path is two notifications, each narrowed by object identity:

```text
⌘L menu item -> BrowserSession.requestAddressFieldFocus()
             -> .browserFocusAddressField   (object = that BrowserSession)
             -> toolbar listener matches the session, re-posts
             -> .browserAddressFieldShouldFocus (object = that session's AddressFieldModel)
             -> the AddressField observing exactly that model becomes first responder
```

No global keyboard monitor, no key polling and no Chromium key interception is
involved.

The field also reports *taking* the keyboard itself, from
`NativeBrowserAddressField.becomeFirstResponder`, and the end of editing still
arrives as `controlTextDidEndEditing`. AppKit does not reliably deliver the
begin-editing callback for a programmatic focus change, and without that signal
the session would not know the field owns the keyboard (section 56).

## 56. Focus model

Keyboard ownership has one rule, applied in one place:
`BrowserWorkspaceStore.withSelectionTransition(_:)` - **the keyboard follows the
page only when the page had it**. Every path that can move the selection runs
inside that transition (a Space switch, tab switch, `⌘T`, `⌘⇧T`, closing the selected tab and
the replacement tab a last-tab close creates), so those paths cannot drift apart:

```text
capture the outgoing selected session and whether its PAGE holds AppKit focus
  -> run the change (collection mutation, session registration; no view work)
  -> selection did not move?  stop: the keyboard stays with whoever owns it
  -> outgoing.blur()                  CEF focus + that session's AppKit responder
  -> publish state, sync the surface  (old container hidden, new one visible)
  -> the page had the keyboard?
       yes -> incoming.focusPage()    now, and when its browser is ready
       no  -> incoming.blur()         record that the page must not take it
```

Consequences:

- **Background work never touches focus.** `createTab(select: false)` and
  closing a background tab move no selection, so the transition publishes the new
  tab order and returns without blurring or focusing anything. A background tab's
  container is hidden before its browser is created, so that browser cannot take
  the keyboard either.
- **A tab change never pulls focus out of the address field.** When the outgoing
  page did not hold first responder, the incoming session is explicitly told that
  the page must not take it; neither the pending browser creation nor the deferred
  half of `focusPage()` can then move the field editor.
- **A hidden surface is never made first responder.** `focusPage()` refuses
  unless the container is the visible selected surface, and the main-queue hop
  inside it re-checks that. An explicit `makeFirstResponder:` succeeds even for a
  hidden view, so the gate is at the call site rather than left to AppKit.
- **Chromium creation is asynchronous, so the intent is state, not a call.**
  `BrowserSession.wantsPageFocus` is set by `focusPage()`, cleared by
  `blur()`, and `browserBridgeDidCreateBrowser` takes the keyboard only when
  `wantsPageFocus && containerView.isSurfaceVisible`. A browser that arrives
  after its tab was hidden again - or after the keyboard moved into the address
  field - is created without focus, and says so in the log
  (`browser created without taking focus`, with the tab id, visibility and
  intent; no URL, no page text).
- **Chromium's own focus request is answered, not ignored.** A browser focuses
  itself when its first navigation starts, and that happens asynchronously -
  after the tab may have been hidden again. `CEFClientHandler` therefore
  implements `CefFocusHandler::OnSetFocus` and forwards the request through
  `BrowserBridge` to the session, which allows it only while the session is the
  visible selected surface *and* the keyboard is meant for page content
  (`isSurfaceVisible && ownsPageKeyboard`; logged with the tab id, the CEF
  source, the visibility and the intent). Without that answer, a background tab
  that merely started loading would make its hidden Chromium view AppKit's first
  responder - gating the application's own `-setFocus:` alone is not enough.
  The CEF source is logged but deliberately not part of the decision: CEF reports
  a "system" request for view-level focus changes too, including the one that
  follows a newly created browser, so it cannot be read as "the user asked for
  this".
- **The address field reports taking the keyboard itself.** AppKit does not
  reliably deliver `-controlTextDidBeginEditing` for a *programmatic* focus
  change, so ⌘L used to leave the session believing the page still owned the
  keyboard - and the next tab change then stole focus out of the field.
  `NativeBrowserAddressField.becomeFirstResponder` now reports the focus gain
  through the representable's coordinator (the end of editing still arrives as
  `controlTextDidEndEditing`), so "the native field owns the keyboard" is state
  the session actually has.
- **Creating a tab hands the keyboard to the new page only when the page had
  it.** With `select: true` and page focus on the old tab, the old page is
  blurred, the new surface is shown, and the new page receives focus as soon as
  its browser exists. With the address field focused, the field editor stays
  first responder (the new session is told the page must not take the keyboard,
  and Chromium's own focus request for the new browser is cancelled) while the
  toolbar re-binds to the selected session's model.
- **Closing the selected tab transfers the keyboard** to the tab the collection
  selects (right neighbour, else left, else the last-tab replacement), and the
  hand-over happens before the closing session is asked to close.
  `-completeClose` clears only that browser's own CEF focus and only that browser
  view's AppKit responder (`NBResponderBelongsToView`), so the new selection keeps
  the keyboard. First responder does not end up empty.
- **Background-tab close** must not steal focus. `-completeClose` always releases
  the closing browser's own CEF focus, and clears AppKit's first responder only
  when (a) the responder belongs to the view being destroyed, or (b) the close is
  part of application termination.
- **Chromium first responder**: the CEF host view is made first responder by
  `BrowserBridge -setFocus:YES`. `-setFocus:NO` only clears it when the current
  responder actually belongs to that browser view
  (`NBResponderBelongsToView`), so releasing one tab never disturbs the field
  editor.
- **The Milestone 2 Cmd+Q fix is preserved** through (b):
  `ApplicationRuntime.requestBrowserClosure()` calls
  `BrowserSession.close(terminating: true)`, which reaches
  `-[BrowserBridge closeForApplicationTermination:YES]` and sets
  `_releasesFirstResponderOnClose`. An ordinary tab close passes `NO`.

## 57. Multi-Space application shutdown

The application termination architecture is unchanged at the AppKit boundary, but
Milestone 4 changes the runtime set from one tab collection to every live session
in every Space. `BrowserSessionManager` is the only liveness registry.

```text
Cmd+Q / red button / NSApp.terminate
  -> AppDelegate.applicationShouldTerminate -> .terminateCancel
       (cancellation lets the native key event and any enclosing CEF call return)
  -> ApplicationRuntime.Terminator.start()
  -> a zero-delay timer on the default run-loop mode runs step() on a clean stack
  -> runtime.requestBrowserClosure()
       -> workspaceStore.requestCloseAllForTermination()
            -> sessionManager.requestCloseAllForTermination()
            -> isTerminating = true              (no replacement tabs, no snapshots)
            -> one CloseBrowser per live session, in the same turn: they close in
               parallel, and OnBeforeClose may arrive in any order
  -> each OnBeforeClose -> typed onLiveSessionDidClose -> scheduleStep()
  -> hasLiveBrowsers == false
  -> termination:browsers-closed
  -> CefShutdown exactly once (ApplicationRuntime.shutdownCEF is idempotent and
     counted; the integration test asserts the count is 1)
  -> termination:finished -> NSApp.terminate(nil) -> .terminateNow
```

- **Closing sessions already in flight** are simply part of `sessions` until
  their OnBeforeClose arrives, so `hasLiveBrowsers` keeps the coordinator
  waiting for them. A tab that started closing before Cmd+Q is closed exactly like
  any other.
- **No replacement tabs during termination**: `WorkspaceCollection.close` uses
  `WorkspaceTabCloseReason.applicationTerminating`, and `createTab` refuses
  while the runtime manager is terminating. The recently-closed stack is not
  written either.
- **There is no production timeout fallback.** `ApplicationRuntime.Terminator`
  advances only from the typed `onLiveSessionDidClose` callback and calls
  `CefShutdown` only after the manager reports zero live sessions. The verifier
  has an external watchdog so a lost callback fails the test instead of changing
  the application's shutdown semantics.

## 58. Address-bar and tab shortcuts

Browser commands are AppKit menu items (`AppCommands.swift`), because NSMenu
matches a key equivalent before the first responder sees the event, which is what
makes them work while Chromium owns the keyboard.

| shortcut | action |
| --- | --- |
| ⌘L | focus the selected tab's address field, select all |
| ⌘R | reload / stop the selected tab |
| ⌘[ ⌘] | back / forward in the selected tab |
| ⌘T | new tab |
| ⌘W | close the selected tab |
| ⌘⇧T | reopen the most recently closed tab |
| ⌘1…⌘8 | select tab by position |
| ⌘9 | select the last tab |

Every action resolves `workspace.selectedSession` when it runs, so a menu item can
never act on a tab that is no longer selected.

**⌘W ownership.** The scene installs AppKit's standard window Close item, which
also claims ⌘W; two items with one key equivalent resolve by menu order, which is
not a contract worth relying on. `MainMenuDump.claimCloseTabShortcut()` therefore
removes the window-closing item from the File menu at launch, leaving exactly one
plain ⌘W: `Tabs > Close Tab`. The title-bar close button is unaffected - it calls
`-performClose:` on the window directly - so the red button still closes the
window and therefore the application. `--dump-main-menu` prints the real menu at
launch and again at termination, and `verify_milestone3.sh` asserts that exactly
one ⌘W item exists in each dump and that it is the tab command.

## 59. Popup routing

`CEFClientHandler::OnBeforePopup` always cancels the unmanaged CEF popup - a
native CEF child window would not be owned or closed by anything - and reports
the target URL to its bridge instead. `BrowserBridge` forwards it to its
`BrowserSession`, which raises `onOpenNewTabRequest`; `BrowserWorkspaceStore`
resolves the source tab's Space and opens the URL as a managed tab there. The
current tab is no longer replaced.

The URL is never formatted into a log in the Objective-C++ layer: the workspace
store reports it through `URLLogSanitizer`, so a popup URL carrying an OAuth code
or a signature cannot leak.

Intentionally deferred: `window.opener`, JavaScript popup object identity, OAuth
child-window scripting (`window.open` handle postMessage), custom popup
dimensions, and `no_javascript_access`.

## 60. Recently closed

⌘⇧T pops the newest `ClosedTabSnapshot` and creates a **new** `BrowserTab`
(with a fresh UUID), a **new** `BrowserSession` and a **new** `CefBrowser` in
the snapshot's original Space and at its original index, then selects it.
Nothing about the closed runtime is reused and its tab identifier is not
recoverable from the snapshot.

Only an ordinary user close records a snapshot, and only for a tab that had
committed a URL - reopening an empty "New Tab" is not offered. Termination closes
record nothing.

The stack is in memory only, bounded to 10 entries, and is not written to disk
(Milestone 3 section 35).

## 61. Single window

`NativeBrowserApp` uses a `Window` scene, not a `WindowGroup`. The runtime owns
exactly one `BrowserWorkspaceStore`, one `BrowserSessionManager` and one set of
Chromium containers, so a scene that could create a second window would mount
the same Spaces - and the same `NSView`s - twice. Per-window workspaces are a
later milestone; the invariant is enforced here.

## 62. Known limitations of the Milestone 4 implementation

- **One window only.** `Window`, not `WindowGroup`; there is no per-window tab
  collection yet.
- **The sidebar remains intentionally scoped.** It uses a placeholder globe
  instead of favicons (no favicon fetching), and has no drag reordering,
  pinning or tab groups; Milestone 5 adds only native hover/close affordances
  and the visual material treatment.
- **No tab suspension.** Every open tab in every Space keeps a live
  `BrowserSession` and a live `CefBrowser`; only the selected tab's container is
  visible.
- **No persistence or session restore.** Space names, membership, ordering,
  selection and the recently-closed stack are in memory only and are gone after
  relaunch.
- **No Space deletion.** Milestone 4 supports create, rename and select; it does
  not expose deletion.
- **Popup semantics are minimal.** Only ordinary `target=_blank` / `window.open`
  navigation is routed to a tab; see section 59 for what is deferred.
- **Renderer-crash recovery is not implemented.** A crashed renderer surfaces
  through `OnLoadError` as a failed load; there is no crash page or automatic
  reload.
- **`--use-mock-keychain` is still in the CEF bootstrap.** Unchanged by
  Milestone 4 and still development debt to revisit before signed distribution
  or password storage.
- **The integration self-test runs inside the real application.** A hand-rolled
  `RunLoop.main.run(until:)` harness delivers `DoClose` but defers
  `OnBeforeClose` for a loaded page by minutes, so `--spaces-self-test` drives the
  real window, the real surface host and the real `NSApplication` run loop
  instead. It observes AppKit's real first responder for the focus rules
  (`holdsAppKitKeyboardFocus`), but it synthesises no key events: what a keystroke
  does - Cmd-T, Cmd-W, typing into the page, Chinese IME - remains manual.

## 63. Milestone 4 implementation record: Spaces

Milestone 4 is an in-memory workspace layer over the Milestone 3 runtime.
`BrowserSpace`, `WorkspaceCollection` and `ClosedTabSnapshot` are pure
Foundation domain types. `BrowserWorkspaceStore` is the sole mutable domain
owner: it owns Space order, tab membership/order, the selected Space, each
Space's selected tab, the recently-closed stack, and the selection/focus
transition. The pure collection is compiled into `NativeBrowserTests` and is
covered by 22 deterministic tests without AppKit or CEF.

The runtime graph is:

```text
ApplicationRuntime
  -> BrowserWorkspaceStore
       -> WorkspaceCollection
            -> [BrowserSpace] -> ordered [BrowserTab] membership
            -> selectedSpaceID -> per-Space selectedTabID
            -> recentlyClosed [ClosedTabSnapshot]
       -> BrowserSessionManager
            -> tabID -> BrowserSession -> BrowserBridge -> CefBrowser
            -> tabID -> ChromiumContainerView
            -> weak BrowserSurfaceHostView
```

The manager deliberately does not own domain tabs, Spaces, ordering, selection
or recently-closed history. It retains every live runtime and every container
across Spaces; `BrowserSurfaceHostView` mounts them all and the manager toggles
visibility so switching Spaces or tabs never recreates a Chromium browser.
The toolbar resolves the store's effective selected session, and metadata or
navigation callbacks are keyed by the originating session's tab identity.

Space switches use the same focus transition as tab switches. A pending
`OnAfterCreated`, a hidden Space callback, or an inactive popup cannot change
the effective selection or steal the address field's first responder. Popup
URLs are routed by the source tab's Space. Ordinary closes record the source
Space and index; closing the last user tab creates a replacement in that same
Space; reopening creates a new tab/session/browser in that Space. Termination
requests closure for every live session, creates no replacement or snapshot, and
waits for every typed `OnBeforeClose` release before the single `CefShutdown`.

## 64. Milestone 5.1 implementation record: first-party macOS visual refinement

Milestone 5.1 changes presentation only. NativeBrowserApp keeps the standard
SwiftUI Window scene, while MainWindowView uses the public AppKit full-size
content layout APIs to let the content continue behind the native titlebar.
The title text and titlebar background are transparent, but the titled window,
traffic lights, menu bar, resizing and full-screen behavior remain native. The
content hierarchy is a semantic window background with a continuous 248-point
sidebar beside a browser column containing one flat toolbar and the stable
surface host.

The sidebar is composed of a titlebar-safe content inset, a Space section
header, Space rows, a restrained `Tabs` header, tab rows and a pinned New Tab
footer. Space and tab selection still come only from BrowserWorkspaceStore; the
rows add only ephemeral hover state. Selected Spaces and tabs use semantic
neutral selection surfaces plus an accent symbol/leading indicator, so
selection does not depend on saturated color or transparency alone. Tab close
controls are discoverable on hover or for the selected row, and loading keeps a
small native progress indicator.

BrowserToolbarView uses native SF Symbols and compact AppKit-style icon
controls for Back, Forward and Reload/Stop. Its address capsule adds a neutral
site-symbol placeholder, semantic background/stroke colors and a stronger
focused/editing treatment. AddressField remains the one
NSViewRepresentable/NSTextField; only its bezel/background/typography were
restyled. Its field editor, focus notifications, edit-buffer invariant, IME,
Escape, Return and Cmd+L behavior are unchanged.

The actual installed SDK is macOS 27.0 with an existing macOS 26.0 deployment
target. Structural panes use AppKit's semantic `NSVisualEffectView` sidebar and
header materials within the window; Liquid Glass is reserved for the compact
address capsule, with a semantic regular-material fallback if the deployment
target is lowered later. No custom blur engine, screenshot blur, canvas
rendering or fake titlebar is involved. The browser content is never passed
through a glass modifier, clip or mask. BrowserSurfaceFrame is a transparent
pass-through around the unchanged BrowserSurfaceView representable, so
BrowserSurfaceHostView and its native CEF child views remain stable.

Semantic colors/materials are used throughout the shell for light/dark
appearance and for the native reduced-transparency path. The remaining visual
limitations are intentional: placeholder globe icons remain in place of fetched
favicons, there is no sidebar collapse control, and the browser surface keeps a
square native rendering boundary where clipping could risk CEF windowed
rendering.
