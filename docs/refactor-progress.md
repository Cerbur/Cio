# Cio structural refactor progress

Rollback point: local tag pre-cio-refactor at f052f5334e91bc20bba9ffbcf15f7e0a45ebc549. Work is on main; no push, amend, rebase or reset.

## Original baseline (2026-10-07)

| Check | Original result | After structure changes |
| --- | --- | --- |
| Required Debug build | PASS after granting compiler-plugin execution permission | PASS after Stage 0 |
| Unit tests | 244 PASS, zero failures | PASS after Stage 0 |
| Original runtime verifier | PASS | PASS after Stage 0 |
| Original rendering verifier | FAIL: 4 legacy close-harness checks | Not counted as passing |
| Original navigation verifier | FAIL: 8 obsolete source assertions | Retired assertions, not fixed behavior |
| Original tab verifier | FAIL: 13 checks including old source/test names and 3 shared-editor assertions | Retired assertions, not fixed behavior |
| Original workspace verifier | FAIL: 12 checks including old source/test names and the same 3 shared-editor assertions | Retired assertions, not fixed behavior |
| Secret scan | CLEAN | PASS after Stage 0 |
| App/framework/five Helpers signatures | All PASS | PASS after Stage 0 |
| Main/Helper direct CEF linkage | None | PASS after Stage 0 |

Raw original evidence is in /private/tmp/cio-refactor-baseline. The new responsibility-based verification does not claim those historical failures were repaired. Numbered scripts remain compatibility forwarding entry points; the binary's command-line switches and diagnostic behavior are unchanged.

## Stages

| Stage | Commit | Status |
| --- | --- | --- |
| C — Current-design documentation and verification cleanup | 4838518 | Complete; all current automated checks passed |
| 0 — Full Cio rename | Pending | Complete; current checks, Debug/Release, 244 tests and bundle checks passed |
| 1 — CioModel | Pending | Not started |
| 2 — CioEngine | Pending | Actual-call protocol review; autonomous implementation authorized |
| 3 — CioUI | Pending | Not started |
| 4 — Diagnostic placement | Pending | Not started |

Model extraction also requires the existing pure BrowserTab, BrowserSplitLayout and WorkspaceSessionSnapshot dependencies of BrowserSpace/WorkspaceCollection. No runtime policy is moved into the pure model package.

Native/visual checks remain unverified; their original lists and current shell checks are in manual-verification.md.

## Cleanup validation attempt (2026-10-07)

The required Debug build passed and all 244 standalone unit tests passed. The runtime verifier passed its headless CEF lifecycle checks, then the running Bash script reported a syntax error near its AppKit container assertion and exited 2. The agent rewrote this script while it was running; this likely invalidated Bash's buffered file position. All scripts pass a subsequent static `bash -n`, but this is not successful runtime verification. The remaining responsibility checks and new secret scan were not reached. No cleanup commit or rename has been made.

Evidence: /private/tmp/cio-refactor-cleanup/validation.log and /private/tmp/cio-refactor-cleanup/unit-tests.log. Product Swift, Objective-C++ and CEF packaging behavior have not been edited by this cleanup. Work remains on main at the rollback tag. No reset or discarded changes.

## Authorized verification repairs

The later session-restore compatibility run exposed three obsolete assumptions (old insertion order and seed labels that live Chromium titles replace); its script now verifies persisted UUID order/selected Space directly and reports those assumptions as retired coverage. Real lazy activation, reuse and teardown remain required. A repeated native test run exposed a pre-existing timing race in NavigationAutocompleteTests: a fixed 80 ms sleep followed by unchecked indexing could crash under load. The test now waits up to two seconds for the expected requests and guards indexing; production autocomplete is unchanged. The download hash oracle was corrected to match the fixture bytes after a cleanup text replacement altered the oracle accidentally.

The first bounded quit-soak launch timed out after CEF initialized because SwiftUI's window did not appear after a private diagnostic window launch. Isolated soak processes now use the existing Release verifier's `-ApplePersistenceIgnoreState YES` policy. The duplicate pending soak was terminated by the agent; its result is not accepted as coverage. A cleanup integration error passed `clean` after `build`, removing Release output; build.sh now places extra actions before the final build, and Release verification stops if the executable is absent. Both are verification repairs, followed by a full stability rerun.

## Cleanup verification result

After the authorized repairs, Debug build/244 unit tests, runtime, rendering, navigation, tabs, workspace (44 current checks; three retired focus checks), restore, history/downloads, stability (stress/lazy/beforeunload/two automatic soak iterations), Release and secret scan passed. The restore drivers retain three legacy failing assertions, explicitly reported as retired coverage; UUID graph/selected Space and all remaining runtime checks are validated independently. Original baseline failures above remain failures. No visual/native manual checks were performed.

Release clean also removes Debug products. verify_current.sh rebuilds the requested configuration before completion and checks App, framework and each Helper individually. No product behavior was changed by this cleanup.

## Rename namespace

The main bundle identifier is now com.example.Cio; Helpers are com.example.Cio.helper plus the existing process suffixes. Default profile/session/history storage is ~/Library/Application Support/Cio. CIO_DATA_DIR, CIO_DOWNLOADS_DIR and the other CIO_* development overrides replace the previous product-prefixed environment names. Existing profile/session/history and preference domains remain in the previous namespace, untouched; there is no implicit migration. Chromium Safe Storage remains Chromium's own name. Packaging logic and the shared framework path are unchanged.

## Stage 0 verification retry

The renamed clean Debug build and 244 tests passed, as did runtime/rendering/navigation/tabs/workspace/restore/history/downloads, stress/lazy/beforeunload and both quit-soak runs. The first Release smoke timed out (124), with neither the SwiftUI window nor page load: private diagnostic-window saved state suppressed its normal window. CEF had initialized; the external watchdog triggered ordered teardown. This attempt is not counted as passing. The smoke now uses the Release script's existing ApplePersistenceIgnoreState launch arguments, as the isolated quit-soak already does. This is a verification-only repair; CEF packaging and product behavior remain unchanged. Evidence: /private/tmp/cio-refactor-stage0/first-attempt and validation.log.

The Stage 0 retry passed all stability and Release checks; its smoke recorded both swiftui:main-window-appeared and browser:first-load-finished. Final Debug rebuild and all 244 tests passed. App/framework/five Helpers passed codesign --verify --deep --strict individually; otool reports no direct CEF dependency for the main or Helper executables. Tracked old-name variants and old-name filenames have zero matches. Final evidence is in /private/tmp/cio-refactor-stage0/final-evidence. The full current verifier now invokes all numbered compatibility entry points, which exec the same responsibility checks.
