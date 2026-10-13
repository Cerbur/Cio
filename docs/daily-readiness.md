# Daily use: workspace, login and input reliability

Scope: P0 1–3 from the daily-use assessment. Existing shell geometry, native
traffic lights, glass controls and animation parameters remain the contract in
AGENTS.md.

## Workspace persistence and recovery

- Each durable mutation saves an atomic `session-v1.json`. Before replacement,
  the previous validated workspace is atomically saved as
  `session-v1.backup.json`. A first save also creates a backup.
- Loading validates the complete domain graph. A damaged primary is retained
  as `session-v1.damaged-<UUID>.json`; the backup is validated before recovery.
  A damaged backup is also preserved before a subsequent save replaces it.
- Recovery repairs the primary without rotating away the surviving backup.
  If neither copy is usable, Cio starts a new workspace and reports that the
  original files were preserved. A backup can predate the latest mutation.
- Files use private permissions. If preservation or saving fails, Cio reports
  it, offers retry and access to the data directory, and vetoes Cmd-Q and native
  window close until the current workspace can be saved.
- The native bootstrap `about:blank` cannot replace a requested/restored URL
  or title before the requested navigation commits. Explicit blank navigation
  is still supported. A navigation submitted before native browser creation
  is retained as the latest request.
- Renderer failure keeps the tab identity and presents a native Reload action.
  Reload is explicit; it does not automatically resubmit forms. Unsaved page
  content is not recoverable merely from a workspace URL snapshot.

## Login persistence

Chromium remains the owner of cookies and encryption. A global change listener
flushes its cookie store in bounded one-second batches while Cio runs, including
HttpOnly mutations, without reading or logging cookie values. It reconnects when
the network service disconnects. Normal termination still waits for Profile
preferences and the final cookie flush before engine shutdown.

This reduces the loss window on force quit; it cannot guarantee persistence
before that asynchronous write completes or override a site's expiry/logout,
clear-on-exit policy or account revocation. The existing profile restores session
cookies alongside Cio's workspace.

Use a fixed signing certificate for updates, as documented in README.md. An
ad-hoc development build cannot promise stable Keychain authorization across
changed signatures. Encryption and security prompts are not bypassed. Legacy
CEF encrypted-cookie migration remains a separate, unverified capability.

## Keyboard and editor lifetime

The mounted address field and Spotlight retain native AppKit field editors.
Deferred focus checks the current presentation, visibility and attached sheets.
A dismissed Spotlight or retired page's address field cannot reclaim the shared
editor. A mounted editor whose text is hidden behind the visible compact address
label can still take explicit Cmd-L focus; the owning presentation decides this.
Chromium's deferred and native focus requests also exclude native address/find
editing and sheets. IME marked text does not submit navigation; the action-based
address submission path applies the same check.

## Verification entry points

```sh
CONFIGURATION=Debug Scripts/build.sh build-for-testing
xcrun xctest build/DerivedData/Build/Products/Debug/CioTests.xctest
PYTHONDONTWRITEBYTECODE=1 python3 Scripts/verify_daily_persistence.py
```

The persistence verifier creates an isolated temporary profile and a loopback
server. It checks encrypted cookie mutations before force quit, the workspace
while the restored response is pending, and exact workspace plus both session
and persistent HttpOnly cookies after force quit and clean quit. Its default
uses the real Keychain; `--mock-keychain` is explicitly weaker coverage.

The fixture server's `/daily` page supports manual login-cookie, popup callback,
opener/close and keyboard acceptance. It is a disposable mechanism fixture,
not a real OAuth provider. Actual GitHub login, native key events, Chinese IME,
split focus and material outlines require computer-use acceptance on the fresh
Debug product. Results must distinguish these from compilation and model tests.

## Acceptance record — 2026-10-13

- Final focus-fix Debug build passed through the required repository script;
  192 standalone XCTest cases passed, zero failures. Logs:
  `/private/tmp/cio-p0-build-focus.log`, `/private/tmp/cio-p0-unit-focus.log`.
- The real-Keychain persistence verifier passed live encrypted mutation flush,
  pending-response restore protection, force-quit restore and clean-quit restore.
  Both HttpOnly cookie types and the exact durable workspace were retained.
  Log: `/private/tmp/cio-p0-persistence-final.log`. This run preceded the final
  editor-visibility correction; persistence and native cookie code did not change
  afterward.
- Computer use on fresh Debug PID 47085 with an isolated profile confirmed two
  Spaces, a Space Pin, restored split panes, selected-pane paste navigation and
  Back, fixture sign-in, popup opener, callback delivery and self-close.
- Computer use also exposed explicit Cmd-L being blocked by the new hidden-field
  guard. The final correction distinguishes hidden editor text from a retired
  presentation, with a new native regression case. The subsequent GUI retest
  passed as recorded below.
- The computer-use app-path selector subsequently opened a default-data process
  beside the isolated process. Automatic approval review refused quitting that
  default window because it could close unsaved user work. The default window
  was left open until the user closed it. Correct instance selection and the
  final focus retest subsequently passed. GitHub account login/restart, actual
  Chinese IME composition and recovery-sheet/crash-panel visual acceptance
  remain pending.
- No usable code-signing certificate was found on this host. Real-Keychain tests
  establish same-build persistence, not authorization stability across ad-hoc
  signature changes. Configure a fixed signing identity before claiming that
  part of update acceptance.

### Continued acceptance after user closed the default window

- Launched the exact Debug app through LaunchServices with `CIO_DATA_DIR` set to
  the existing isolated GUI profile. Verified only PID 62712 was running and its
  executable was the repository Debug product. Using LaunchServices avoided the
  selector's duplicate default-data launch.
- Direct Cmd-L from page focus selected the complete current URL. Pasted
  navigation changed only the selected left split pane. Back restored it;
  Escape discarded unsubmitted address text. Spotlight returned focus to the
  page on dismissal. A separate Cmd-T followed immediately by typing retained
  the complete `immediate-keystrokes` input.
- The GitHub HTTPS login page loaded inside Cio with username/password, passkey
  and third-party sign-in controls. Account sign-in and its restart acceptance
  are awaiting the user's credential/second-factor handoff. Page availability
  alone is not an authenticated-login pass.
- The same build's runtime log reports the Touch ID authenticator unavailable:
  its configured `.org.chromium.Chromium.webauthn` Keychain access group does not
  match an executable entitlement. Chromium's availability check rejects this
  before biometric authentication. A visible GitHub passkey control therefore
  does not establish native Touch ID support. That path requires an appropriate
  signed identity, matching engine configuration and entitlement, plus separate
  device acceptance; ordinary cookie persistence does not establish it.

### GitHub passkey crash diagnosis

- The user-triggered GitHub passkey request crashed isolated Debug PID 62712
  at 12:13:26. System TCC logs identify `kTCCServiceBluetoothAlways` and explicitly
  reject the request because the main app has no
  `NSBluetoothAlwaysUsageDescription`. The runtime stack terminates at
  `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`. This is distinct from the Touch ID
  availability check above.
- The app's source Info.plist now explains Bluetooth use for signing in with a
  nearby device's passkey. The declaration allows macOS to ask for permission;
  it does not grant permission or enable the separate native Touch ID path.
  The fresh-product build passed; original-path regression results follow below.
- After the Bluetooth declaration fix, real GitHub retry exposed a second
  deterministic crash in `NativeWidgetMac::InitModalType`: the Authenticator
  request Views dialog assumed its AppKit parent was a NativeWidgetMac host.
  Log: `/private/tmp/cio-p0-passkey-gui.log` (PID 72534). TCC accepted the usage
  declaration; this subsequent failure was a distinct window-parent invariant.
- `CioWebAuthnDialogs.mm` now presents the original Chromium authenticator Views
  widget as a native AppKit sheet, keeping its security-dialog tracker, WebAuthn
  verification and callbacks. `WebContentsModalDialogManager` still blocks input
  and manages visibility and navigation/closure; the adapter detaches the sheet
  on hide/close and unregisters its widget and host observers. Chromium's sheet
  updates route through that adapter. Stock Chromium keeps its original path.
- The required Debug build passed with the adapter, log
  `/private/tmp/cio-p0-passkey-sheet-build.log`. Computer use verified the unique
  fresh Debug PID 28499 and the same isolated profile restored the GitHub 2FA
  page alongside its Spaces, pin and split group after both crashes.
- `http://localhost:18764/daily/passkey` exercises real WebAuthn discovery with
  a disposable, nonexistent credential. It opened the native device-selection
  sheet with phone/tablet and USB-key choices. Cancellation returned
  `NotAllowedError` to the page while the same app continued running. The host
  name matters: an IP-literal RP correctly fails with `SecurityError` before
  entering the authenticator UI. Start the fixture with
  `python3 Scripts/verification_fixture_server.py --port 18764`.
- The original GitHub `Use passkey` action now opens the native sheet containing
  its phone/tablet QR-code step without crashing. The user is completing account
  authentication; successful authentication and its subsequent restart are not
  counted as passed yet. No agent granted Bluetooth access or changed a TCC
  decision during acceptance. Native Mac Touch ID remains the separate signing
  and access-group limitation described above.

### Cross-device retry diagnostics

- The iPhone reported a connection error immediately after scanning, before
  identity verification. Cio remained alive (the same PID 28499); the GitHub
  request eventually displayed the native timeout sheet. This is a failed
  cross-device authentication acceptance, despite the crash regression passing.
- Chromium's device log shows Bluetooth discovery started and the GitHub QR
  step, followed by timeout without a matching phone advertisement/connection
  event for that request. An earlier disposable fixture request did receive a
  matching advertisement and attempt an Apple caBLE tunnel connection. The
  requesting site, timing and requests differ, so neither observation proves a
  root cause for the iPhone error.
- Read-only network probes used entirely new random test bytes, never the
  account request or QR data. Google's assigned caBLE domain accepted a
  `fido.cable` WebSocket with HTTP 101 both directly and through the Mac's actual
  system HTTP proxy. Apple's assigned domain completed TLS but rejected the
  synthetic `/cable/new` request with HTTP 400 on both paths. That rejection is
  not a test of an iPhone-created Apple tunnel, and does not establish an Apple
  service outage, a phone-network failure or a Cio networking defect.
- GitHub's existing Authenticator app and GitHub Mobile alternatives are
  available. The authenticator-code page has been opened for the user to complete
  authentication while cross-device cause remains unresolved. No proxy, VPN,
  Bluetooth permission or authentication protection was changed for diagnosis.

### Final product acceptance

- The user subsequently completed GitHub sign-in through the phone QR-code
  passkey flow. Computer use observed the authenticated personal Dashboard in
  PID 28499. The earlier connection error remains an unexplained failed attempt;
  successful retry is not evidence that every possible transport failure is
  fixed.
- Normal Cmd-Q completed the cookie flush and clean engine shutdown. The app
  was verified absent before relaunching the same isolated profile as fresh PID
  34072. Its authenticated GitHub Dashboard returned without reauthentication;
  the entire workspace snapshot matched the pre-quit snapshot, including both
  Spaces, the pin and split group. No cookie values were read for this check.
  Logs: `/private/tmp/cio-p0-passkey-sheet-gui.log` and
  `/private/tmp/cio-p0-github-restart.log`.
- Actual renderer-crash acceptance found the new AppKit recovery panel duplicated
  the pre-existing SwiftUI native recovery component. The extra panel and its
  container/session wiring were removed. The existing component keeps the tab
  and offers explicit Reload. The required final Debug build passed:
  `/private/tmp/cio-p0-final-build.log`.
- The final product was launched in a separate disposable recovery profile as
  PID 40727. With a damaged primary and valid fixture backup it showed the native
  recovery sheet, preserved the exact damaged bytes and restored the original
  Space/tab identities and URL. Subsequent page title updates legitimately
  rotated the backup, so primary/backup equality after page loading is not the
  recovery assertion.
- A directory occupying the disposable backup filename forced a real save
  failure. The native error sheet appeared; after dismissing it, Cmd-Q left the
  same process alive and redisplayed the warning. Removing only that test
  blocker and pressing Retry persisted the newly navigated Page B. No signed-in
  profile files were changed by the failure injection.
- On that final product, `chrome://crash` in the fixture tab produced only the
  existing recovery component. Reload returned to Page B while Cio stayed alive.
  The disposable instance then quit normally. Log:
  `/private/tmp/cio-p0-recovery-gui.log`.
- The final product reopened the original isolated GitHub profile as PID 41668.
  Computer use again observed the authenticated Dashboard. Mac-native Touch ID
  and stable authorization across arbitrary future signing changes remain the
  signing/access-group limitations above; this particular rebuilt product did
  retain the GitHub session.
- Early native Ctrl-Space/Caps Lock automation attempts produced Latin text
  without a visible IME candidate panel and were not counted as composition
  passes. Read-only system configuration identifies Apple's Simplified Chinese
  Pinyin; the user uses Caps Lock. The user then triggered a real candidate
  panel in the prepared address editor, and confirmed it was visible.
- Real IME acceptance passed on final Debug PID 41668. The native address
  editor exposed segmented `ni hao` pre-edit text. The first Return ended
  composition and committed the Latin spelling `nihao`, as native Pinyin Return
  does, while the GitHub page remained unchanged. A separate composition followed
  by Space selected the Chinese candidate `你好` without navigating. Escape
  restored the committed `github.com` address and returned focus to its HTML.
- Spotlight passed the same real-composition checks: `ni hao` pre-edit, first
  Return ending composition without submitting a search or creating a page,
  and Space committing `你好`. Escape dismissed Spotlight and returned focus
  to the original authenticated GitHub page. Composition behavior was observed
  directly; it was not inferred from pasted Chinese text.
