# Daily-use comparison with Arc — 2026-10-20

## Updated after the user's Arc recording

Control-Tab uses a horizontal MRU switcher with at most five candidates
(current presentation plus four recent presentations), spanning Spaces. A split
is one presentation unit and restores its focused pane. Hold Control and press
Tab to move forward, or Shift-Tab to move backward; release Control to commit.
Escape cancels without changing selection or recency. Left/Right, Return, and
clicking a card are also supported. Menu invocation keeps the chooser open until
confirmation or cancellation.

Candidates freeze for the gesture and omit closed Space Pin bookmarks and tabs
awaiting close. Committing a cross-Space tab selects its owning Space; a Top Pin
keeps the current Space. Highlighting does not load or focus candidate browsers.
Page previews come from Chromium's compositor and a bounded in-memory cache
(up to fifteen panes for five three-pane candidates);
unrendered/restored pages display a native globe placeholder until visited.
Preview persistence and bounded artwork caches are described in
[presentation-cache.md](presentation-cache.md); previews still come from the
page compositor. This supersedes the earlier memory-only implementation.

This supersedes the sequential sidebar traversal described in the original
assessment below. The user-provided recording is the interaction reference.

Interaction/layout follow-up (21:49 and 21:55 recordings):

- Keyboard invocation starts a frozen selection immediately but defers creating
  or ordering the panel until Control has remained held for 50 ms (reduced from
  the initial 200 ms at the user's request). Release
  before that threshold commits immediately without panel appearance/dismissal.
  Repeated selection does not extend the deadline; cancellation and a per-flight
  token prevent an old callback from revealing a later gesture. Menu invocation
  remains immediately visible and latched. This is an input-intent threshold,
  independent of the animation speed preference and Reduce Motion.
- Reference: [Firefox's native Ctrl-Tab implementation](https://github.com/mozilla-firefox/firefox/blob/main/browser/components/tabbrowser/content/browser-ctrlTab.js)
  uses a 200 ms delay to suppress the UI for a quick MRU flip. Cio uses the same
  strategy with a shorter 50 ms threshold and retains its original deadline
  during repeated Tab presses, rather than forcing an early reveal.
- MRU grouping happens before the five-candidate limit. Two/three-pane groups
  occupy one slot, use the newest member's recency and restore their focused
  pane. Closing members are omitted. A workspace consisting of one split has
  no second presentation to cycle to. Persistent split identity is unchanged.
- A split card combines the member previews in pane order and displays only
  its centered favicons beneath them. Combined titles/hosts remain available
  to accessibility and help without visible split-title text.
- Removed the keyboard-instruction footer. One layout source now measures the
  card and native panel height; all four outer insets are 12 pt. Preview clipping,
  selection backgrounds and the native glass use the shared content corner
  radius (14 pt). The transparent dispersion/blur envelope remains separate.
- Added deterministic quick-release/hold/cancellation tests, grouped-MRU and
  restore tests, plus inset checks for one through five candidates at two widths.

Dismissal rendering follow-up (20:44 recording):

- Removed the NSPanel's rectangular WindowServer shadow. The native Liquid Glass
  surface retains ownership of its outline and optical transition.
- Separated resting content bounds from the transparent render envelope. The
  envelope includes the shared 12% dispersion and three blur radii per edge;
  the resting content keeps its center (the later footer removal below reduces
  its height).
- Composited cards/selection/labels together before applying content blur and
  opacity, leaving native glass outside that group. Content dismisses in a named
  55 ms Standard interval; materialize retains its 140 ms Standard flight. Both
  clocks resolve the saved speed preference at flight start and respect Reduce
  Motion. Window removal still uses completion and a flight-identity guard.
- Disabled intrinsic hosting-view window resizing and stopped the retiring
  transparent panel from intercepting clicks.
- `bash Scripts/verify_recent_tab_frames.sh` links against the app's production
  CioUI object. Before the fix it failed shadow/dispersion clearance; afterward
  all four native render-envelope checks passed. The existing focused XCTest
  also passed its narrow-window/editor-focus contract.
  This is a regression for the native causes, not a claim of new 120 Hz
  WindowServer video capture.

Validation of the 21:49/21:55 refinement:

- 117 CioModel tests passed (`/private/tmp/cio-recent-refinement-model.log`).
- Two focused native panel tests passed, covering equal card insets at multiple
  widths and preserving editor focus (`/private/tmp/cio-recent-refinement-panel.log`).
- All four production-object render-envelope checks passed
  (`/private/tmp/cio-recent-refinement-frames.log`).
- Required root Debug build/test build log:
  `/private/tmp/cio-recent-refinement-build.log`.
- No additional app launch or computer-use acceptance was performed for this
  refinement; the live acceptance below describes the preceding implementation.

Validation of the preceding switcher:

- Required Debug build passed: `/private/tmp/cio-recent-tabs-acceptance-build.log`.
- 236 native XCTest cases passed, including five-card sizing in a 640-point
  window and preservation of its native editor's first responder. 111 model
  cases passed, including nine MRU/selection cases. Logs:
  `/private/tmp/cio-recent-tabs-xctest.log` and
  `/private/tmp/cio-recent-tabs-model.log`. Ten native key-equivalent checks also
  passed (`/private/tmp/cio-recent-tabs-key.log`).
- Fresh Debug acceptance used the absolute app path, LaunchServices, a separate
  seven-tab/two-Space profile in `build/verification/recent-tab-switcher/`, and
  the loopback fixture on port 18784. No real-account data was used.
- This time screenshot capture worked. It showed exactly five horizontal
  cards, a selected candidate, current-page compositor content, native globe
  placeholders for unrendered restored pages, and readable title/host labels.
- Menu invocation kept that same chooser open. Right Arrow moved highlight
  from Page A to Popup fixture while Work secondary remained the active page
  and kept keyboard focus. Escape visibly dismissed the chooser without a tab
  switch. Reopening and confirming with Return switched to Popup fixture in
  Other Space and focused its webpage.
- Control-Tab then switched back to Work secondary in its original Space.
  Quick Control-Tab and reverse selection from a native address editor were
  also exercised on the preceding Debug build. The provider serializes native
  held-key actions with observations, so intermediate held-key screenshots were
  checked through the latched menu presentation; frozen repeated selection and
  wraparound are also covered by model tests.

This assessment combines live native-menu inspection of the installed Arc and
Cio, Arc's Next/Previous Tab behavior, Cio source inspection, automated
regressions, and fresh Debug acceptance. It is a focused daily-use assessment,
not a claim that every browser capability or real-account flow was tested.

## Priority

| Order | Gap | Evidence and reason |
| --- | --- | --- |
| 1 | Sequential keyboard tab switching | Arc has Next Tab / Previous Tab and wraps between the last temporary tab and the first Favorite. Baseline Cio's live Tabs menu has positional shortcuts only. This affects repeated navigation throughout every multi-tab session. Implemented here. |
| 2 | Incognito browsing | Arc exposes New Incognito Window. Cio has no shell command or isolated private-workspace lifecycle. Needed for temporary sessions and account troubleshooting. |
| 3 | Print / save-page entry points | Arc exposes Print and Save Page As. Cio has no equivalent application menu/bridge command; Cmd-S currently toggles the sidebar. Chromium context-menu behavior is not covered by this finding. |
| 4 | Page / selection translation | Arc exposes Translation. Cio's translate hooks still show a notice that the panel is not connected. Useful for routine multilingual reading. |
| 5 | Additional windows and profiles | Arc exposes New Window and New Profile. Cio documents one workspace window. Useful for parallel tasks and account separation, but requires separate ownership/persistence work. |

Existing Cio entry points include find, page zoom, history, downloads, reopen
closed tab, pins, Spaces, split pages, password management, and extensions.
Their presence does not imply that every real-world flow was verified in this
assessment. No Arc settings or stored tabs were changed; its original selected
tab was restored after exercising Next and Previous.

## Implemented behavior

- Tabs → Next Tab: Control-Tab. Previous Tab: Control-Shift-Tab.
- Traversal wraps in sidebar tier order: Top Pins, current Space Pins, temporary
  tabs. Global pins appear once. Other Spaces' ordinary tabs are excluded.
- Every split pane can receive selection and page focus without ungrouping.
- Closed Space Pins can be selected again; tabs awaiting runtime close are
  skipped. Empty/single-tab workspaces disable traversal.
- Uses the existing selection/persistence/session machinery and native menu
  dispatch. Chromium's raw key pre-handler routes these equivalents before a
  focused page can consume them. Plain Tab/Shift-Tab keep their normal behavior.
- AppKit's reverse-tab character is used in the menu. Chromium representations
  that retain a plain tab are normalized before matching, avoiding accidental
  forward dispatch. No global keyboard monitor or new custom animation.

## Automated evidence

- `CONFIGURATION=Debug Scripts/build.sh build-for-testing`: test build and app
  build succeeded. Final app rebuild after event-normalization correction uses
  `CONFIGURATION=Debug Scripts/build.sh`.
- 235 standalone XCTest cases passed; 102 CioModel cases passed, including six
  new traversal tests for wraparound, tiers/Spaces, closed pins, split panes,
  closing exclusions, and empty/single-tab state.
- `bash Scripts/verify_tab_shortcuts.sh`: ten native menu checks passed, including
  reverse-tab representations, unrelated modifiers, and disabled dispatch.
- `bash Scripts/verify_zoom_shortcuts.sh`: thirteen existing zoom menu checks
  passed after changing the shared key-equivalent helper.
- Test build log: `/private/tmp/cio-daily-arc-build.log`; final build log:
  `/private/tmp/cio-daily-arc-final-build.log`; XCTest log:
  `/private/tmp/cio-daily-arc-xctest.log`; model log:
  `/private/tmp/cio-tab-traversal-model.log`.

## Fresh Debug acceptance

The old Cio instance was quit before launching the rebuilt app. Live acceptance
uses the absolute repository Debug app path and a disposable profile under
`build/verification/arc-daily-20261020/`, with a loopback fixture on port 18783.
The mock Keychain is restricted to this synthetic profile; these checks do not
establish real-account login or password persistence.

Final acceptance used PID 12015, launched at 15:50:45 after the final build;
the Debug executable timestamp was 15:49:00. The absolute-path selector first
opened an additional default-profile window beside a directly launched test
process. That window was quit without editing its tabs, the synthetic process
was stopped, and the same Debug app was relaunched through LaunchServices with
the disposable environment. Process inspection then confirmed one Cio process;
the inspected UI showed the fixture's Keyboard QA / Other Space names and
loopback URLs, rather than the user's workspace.

Confirmed through native accessibility state and actual key/menu actions:

- Control-Tab selects the right split pane and moves keyboard focus to its
  Chromium page; another press wraps to the Top Pin as a single page.
- Control-Shift-Tab restores the split and right-pane focus, then left-pane
  focus, then reopens the closed Space Pin. Split group identity is preserved.
- Both directions work from the native address editor and focus the incoming
  page. Forward traversal also works while a webpage text input owns focus.
- In Other Space, the cycle contains only its page and the shared Top Pin;
  Keyboard QA's ordinary tabs and Space Pin never enter that cycle. The page's
  `focus-check` input and its field focus survive switching away and back.
- Plain Tab moves from that page input to its link; Shift-Tab moves back.
- Clicking Tabs → Next Tab changes the selected page and transfers page focus.
- Sidebar collapse leaves traversal working; the sidebar was expanded again.
- With only the Top Pin available, Next/Previous are disabled and Control-Tab
  leaves selection unchanged. Cmd-Shift-T restores the closed temporary tab.
- Find reports `1 / 1` for `acceptance`; page navigation and Cmd-[ Back return
  to the original fixture page with its input intact.
- The live Cio File menu has no print, save-page, private-window or new-window
  entry, confirming the menu gaps against Arc.

The computer-use provider returned `Screenshot unavailable` for both Arc and
Cio. These are interaction/accessibility checks; material outlines and animation
appearance were not visually verified. This change adds no shell geometry or
custom animation. Existing user edits to sidebar/drag presentation were retained.
The test app was quit and the loopback server stopped after acceptance. The
disposable workspace saved two Spaces, five tabs, and the original split group.
