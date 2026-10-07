# Cio structural refactor progress

Rollback point: local tag pre-cio-refactor at f052f5334e91bc20bba9ffbcf15f7e0a45ebc549. Work is on main; no push, amend, rebase or reset.

## Original baseline (2026-10-07)

| Check | Original result | After structure changes |
| --- | --- | --- |
| Required Debug build | PASS after granting compiler-plugin execution permission | PASS after Stage 1 |
| Unit tests | 244 PASS, zero failures | PASS after Stage 1 |
| Original runtime verifier | PASS | PASS after Stage 1 |
| Original rendering verifier | FAIL: 4 legacy close-harness checks | Not counted as passing |
| Original navigation verifier | FAIL: 8 obsolete source assertions | Retired assertions, not fixed behavior |
| Original tab verifier | FAIL: 13 checks including old source/test names and 3 shared-editor assertions | Retired assertions, not fixed behavior |
| Original workspace verifier | FAIL: 12 checks including old source/test names and the same 3 shared-editor assertions | Retired assertions, not fixed behavior |
| Secret scan | CLEAN | PASS after Stage 1 |
| App/framework/five Helpers signatures | All PASS | PASS after Stage 1 |
| Main/Helper direct CEF linkage | None | PASS after Stage 1 |

Raw original evidence is in /private/tmp/cio-refactor-baseline. The new responsibility-based verification does not claim those historical failures were repaired. Numbered scripts remain compatibility forwarding entry points; the binary's command-line switches and diagnostic behavior are unchanged.

## Stages

| Stage | Commit | Status |
| --- | --- | --- |
| C — Current-design documentation and verification cleanup | 4838518 | Complete; all current automated checks passed |
| 0 — Full Cio rename | 984ed4f | Complete; current checks, Debug/Release, 244 tests and bundle checks passed |
| 1 — CioModel | df144a2 | Complete; 86 package + 158 native tests and all current checks passed |
| 2 — CioEngine | 9fd0785 | Complete; standalone Engine/App builds, 244 tests and all current Debug/Release gates passed |
| 3 — CioUI | Pending | Complete; independent CioUI/App builds, 244 tests and final full Debug/Release chain passed |
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

## Stage 1 extraction verification

The first standalone package and App builds failed because the CGRect convenience overlay previously came through AppKit; BrowserSplitLayout now explicitly imports system CoreGraphics. The same CGRect/CGFloat values and geometry statements are retained. CioModel has no package dependency and imports no AppKit/SwiftUI/CEF; its other files use Foundation. No unchecked Sendable was added. Original attempt logs: /private/tmp/cio-refactor-stage1-swift-test.log and cio-refactor-stage1-validation.log.

The next Stage 1 current-verifier attempt passed Model 86 tests, App build and remaining 158 native tests, then its ordinary Debug window smoke timed out with only CEF initialization (8 missing-window/lifecycle assertions). The same verified isolation launch option is now supplied by the runtime/rendering/navigation/tabs GUI harness calls, preventing diagnostic-window saved state from contaminating later GUI launches. Product code is unchanged by this repair. This failed attempt remains in the Stage 1 initial-current-verifier evidence.

The Stage 1 retry then passed the repaired GUI gates but the workspace diagnostic remained at CEF initialization for almost two minutes, before any self-test. The agent sent SIGTERM only to its exact repository Debug --spaces-self-test process rather than waiting for the 600-second watchdog. This interrupted run is not passing coverage. All remaining GUI self-test timeout invocations now use the same ApplePersistenceIgnoreState isolation policy (including private diagnostic windows); existing instances of that option are retained without duplication. Raw evidence: validation-retry.log and interrupted-workspace.log under /private/tmp/cio-refactor-stage1.

Stage 1 final verification passed the required Debug build, package-local swift test (86), native XCTest (158), all numbered compatibility verifiers/current responsibility checks, Release, individual bundle signatures/linkage and secret scans. Total distinct existing cases remain 244. Seven-file model audit found no ordinary statement changes; only access/initializers/checked Sendable/imports and updated parsing documentation. Bridge and CEF packaging have no Stage 1 diff. Final evidence: /private/tmp/cio-refactor-stage1/validation-final.log, swift-test.log and final-evidence.

Stage 2's first App build caught an existential Sendable requirement at the existing native-field main-queue focus hop. The common observable protocol now explicitly requires checked Sendable; all implementations are original MainActor classes. No unchecked conformance or scheduling change was introduced. Independent Engine build passed before App integration.

The next Stage 2 integration attempt caught SessionStore.isEnabled still having module-internal access; exporting that original immutable field fixed the workspace persistence caller. The failed build is retained in /private/tmp/cio-refactor-stage2/validation.log and is not passing validation. Engine service audit confirms the twelve migrated files retain their original ordinary statements.

Stage 2 final validation passed all numbered compatibility verifiers, current runtime checks, two quit-soak iterations, Release and the final fresh Debug rebuild, individual signatures/linkage and secret scan. No Bridge or CEF packaging diff is present. Evidence: /private/tmp/cio-refactor-stage2/validation-retry.log and final-evidence. Protocol member-to-caller mapping is in engine-interface.md.

Stage 3 independent CioUI compilation first required an explicitly MainActor-isolated ObservableObject conformance on the new context. App integration then required exporting the existing CioAddressField type/overrides and SidebarTabDrag diagnostic probe accessors. All failed attempts are recorded under /private/tmp/cio-refactor-stage3. No unchecked Sendable, weakened compiler mode or changed original method body is used. Existing concurrency/deprecation warnings also appear in Stage 2 logs and are retained.

Stage 3 full verification first passed the App build and 244 tests, then failed the rendering script’s total-lifetime threshold (20 seconds, including startup and ten seconds residence). That attempt is not passing evidence. The script now requests the existing shutdown-phase trace and checks T0→T7 against its original six-second quit budget, while retaining the full-process watchdog. No production lifecycle or timer changed. Original rendering log: /private/tmp/cio-refactor-stage3/first-render-launch.log; failed run: validation.log.

The timestamp-based retry measured a real 14.1-second delay inside CefShutdown (browser close completed in about eight milliseconds), so it failed the unchanged budget. The same binary with a fresh test profile passed at 71 ms. This supports test-profile contamination as a possible contributor, not a proven CEF diagnosis. Rendering now creates an isolated stateless profile for each launch under build/ and preserves it for inspection. Slow/fresh traces are retained in slow-shutdown-launch.log and fresh-shutdown-launch.log; production lifecycle is unchanged.

The next full retry measured another eight-second CefShutdown with an isolated profile while the independent package compiler ran concurrently. It is retained as a failed attempt (validation-final.log and isolated-slow-shutdown-launch.log). A focused rerun without concurrent compilation passed at 265.5 ms. Profile/host load remain hypotheses, not a proven product fix. Final full validation will run without a parallel compiler; the budgets and production shutdown remain unchanged.

The serial full attempt then passed rendering at 452.8 ms but failed the navigation pump-termination timing gate at 1,475.2 ms (one-second budget); ordering/close/exit checks all passed. The failed timing remains in validation-sequential.log and navigation-slow-shutdown.log. Three consecutive focused trials of the same unchanged binary, each with a fresh profile, passed at 67.6/284.5/70.7 ms without a delayed thread sample. No App Nap override, foreground automation, production change or relaxed budget was used. The intermittent CefShutdown latency remains an unresolved observation even if the final full chain passes.

Stage 3 final complete chain (validation-complete.log) passed App builds, 86 Model + 158 native tests, every compatibility verifier, stress/lazy/beforeunload/two quit soaks, Release, final Debug rebuild, individual signatures/linkage and secret scan. The final rendering/pump termination timings were 620.8/103.4 ms. Prior slow CefShutdown attempts remain failed and unresolved, not erased or relabeled. Final evidence is in /private/tmp/cio-refactor-stage3/final-evidence. The independent final CioUI build and source/host boundary audits are also preserved in this directory’s parent.
