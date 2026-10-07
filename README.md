# Cio

A macOS Chromium browser shell using SwiftUI, AppKit, Objective-C++ and CEF. The native shell owns Spaces, tab tiers, split pages, Spotlight, address editing, History, Downloads and Settings. Chromium owns page rendering and navigation. Browser surfaces and their native editors remain mounted across selection and UI updates.

## Build

Requires macOS 26+, Apple Silicon, Xcode with Swift 6, and XcodeGen. CEF 152.0.6 is pinned by the repository scripts and is not committed.

```bash
Scripts/fetch_cef.sh                  # once, if ThirdParty/CEF is absent
CONFIGURATION=Debug Scripts/build.sh
```

The build regenerates Cio.xcodeproj from project.yml, installs the shared scheme, compiles the wrapper when needed and packages/signs CEF and five Helper applications. The product is build/DerivedData/Build/Products/Debug/Cio.app. Use CONFIGURATION=Release with the same script for Release. Generated projects, CEF binaries and build output are ignored.

The CEF framework is loaded at runtime; otool -L must not show a direct CEF dependency. Scripts/package_cef_runtime.sh stays an Xcode build phase. Helper executable names follow the main product name and share one framework through `../../..`. See [Chromium capabilities](docs/chromium-capabilities.md) for accessibility, Web Inspector/CDP and the codec runtime recipe.

## Verify

```bash
CONFIGURATION=Debug Scripts/verify_current.sh
```

Individual entry points:

| Script | Coverage |
| --- | --- |
| verify_unit_tests.sh | Standalone XCTest and local package tests |
| verify_bundle.sh | Individual App/framework/Helper signatures, identities and linkage |
| verify_runtime.sh | CEF init/pump/shutdown, bundle identity, five Helpers, signatures and linkage |
| verify_rendering.sh | Real application page load, callbacks and typed shutdown |
| verify_navigation.sh | Parser/probe, navigation, reload/stop, redaction and quit ordering |
| verify_tabs.sh | Multi-browser quit, real main menu and URL privacy |
| verify_workspace.sh | Current Space/tab/runtime invariants from the compatibility driver |
| verify_session_restore.sh | Separate seed/relaunch processes, exact persistence and lazy sessions |
| verify_history_downloads.sh | Real CEF history/download callbacks, SQLite and downloaded bytes |
| verify_stability.sh | Tab/Space stress, lazy restore, beforeunload, bounded soak and Release |
| verify_release_candidate.sh | Hardened local Release bundle, rendering, restore, history/downloads |
| check_no_secrets.sh | Tracked files and git history; matched secret values are never printed |

The numbered verify_milestone scripts forward to these responsibility-based scripts for existing callers. No historical feature-stage specification is used as the current implementation contract.

The pre-refactor baseline had passing build, 244 passing unit tests, runtime/bundle checks and secret scan, but failing historical checks. Those failures are recorded separately in [refactor progress](docs/refactor-progress.md). They have not been repaired or relabeled as successful validation. The old browser-close harness is excluded from the rendering gate; three obsolete shared-editor focus expectations in the compatibility workspace driver are explicitly labeled retired coverage. Unexpected runtime failures still fail validation.

[Manual verification](docs/manual-verification.md) covers native keyboard/focus/IME and actual visual behavior. Script results do not claim these checks were performed. Open the freshly built Debug bundle only for explicitly requested computer-use validation.

## Layout

```text
Cio/
  App/                    entry point, scene, menus, runtime, diagnostics, logging
  Bridge/                 Objective-C++ boundary, event support, bridging header
  Browser/                domain values, workspace policy, sessions and CEF containers
  Animation/              shared motion and AnimationValues (see its README)
  UI/
    Main/                 native shell, stable page toolbar, viewports and traffic lights
    CommandBar/           NSTextField address editor, model and native focus notifications
    Sidebar/              tab tiers, retained rows, dragging and drop projection
    Spotlight/            new-tab input, completion and presentation
    Internal/             History and Downloads presentation
    Settings/             settings UI
    Visual/               native glass, navigation buttons and shared favicon views
  Persistence/            session JSON and SQLite history
  History/                history domain/service
  Downloads/              safe destination policy and process-memory download state
  Helper/                 separate CEF process entry point
  Resources/              Info.plist and signing entitlements
  Tests/                  standalone logic/native-model tests
SchemeTemplates/Cio.xcscheme
Scripts/                  reproducible build and verification tools
ThirdParty/               untracked CEF distribution and wrapper products
project.yml               sole Xcode project definition
AGENTS.md                 shell, native-control, animation and validation constraints
ARCHITECTURE.md            current ownership, lifetime and interaction design
```

## Architecture decisions

- CEF initialization, pumping and shutdown belong to the application, not views. Termination cancels the native request, waits for typed OnBeforeClose from every live session, calls CefShutdown once and retries termination.
- WorkspaceCollection owns domain identity/order/policy. BrowserSessionManager owns only live sessions and stable containers. Restored inactive tabs are lazy; selection cannot rebuild a live browser.
- Each page retains a tab-bound toolbar/editor and outer viewport. Section, tab and split changes preserve native component identity. Shared layout dimensions come from BrowserShellLayout.swift.
- Address editing uses native NSTextField and its field editor. The committed URL and edit buffer are separate; background callbacks cannot overwrite active input. Selecting another page ends the outgoing address edit.
- Cmd-L/R/[/] and tab commands are native menu equivalents. Cmd-T opens Spotlight. Current selection is resolved at action time.
- Popups route to managed tabs using the source runtime identity. CEF C++ objects and download callbacks stay behind the bridge.
- Navigation and persistence retain complete URLs. Every URL log/probe uses the single URLLogSanitizer policy.
- Native materials, system controls and animation APIs retain their normal interactions. Animation tuning and speed scaling live in Animation/; AGENTS.md records the required geometry and motion contract.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the current design and lifetime details.

## Data and development signing

The main bundle ID is com.example.Cio. Browser profile, session-v1.json and history.sqlite3 use ~/Library/Application Support/Cio/ by default. CIO_DATA_DIR overrides storage for verification; CIO_DOWNLOADS_DIR overrides the download destination. Local data is not migrated implicitly.

Development signing is ad-hoc. A changed binary identity can cause a Chromium Safe Storage keychain dialog that blocks CEF initialization. The scripts cannot answer it. Stop and report a blocked run; do not change keychain contents or policy to manufacture a passing result.

The app currently supports one workspace window. CEF navigation history, form/scroll state and full popup window.opener semantics are not restored. Developer ID signing/notarization and final distribution assets remain outside the current local build.
