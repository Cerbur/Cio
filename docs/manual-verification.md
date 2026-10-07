# Manual verification

These checks have not been performed. Use the freshly built Debug application when computer-use validation is explicitly requested. The current policy has a stable toolbar/editor per page, Cmd-T opens Spotlight, and selecting another page ends the outgoing address edit.

The following original script lists are preserved verbatim as requested. Historical expectations about keeping a shared address editor across tab/Space changes are superseded by the current policy above; they are not automated passes.

## Compatibility checklist 2

```text
REQUIRES MANUAL VERIFICATION (not covered by this script):
  * real Cmd+Q with page focus and address-field focus; record with
    --log-shutdown-timing, then run Scripts/check_shutdown_timing.py LOG EXIT_CODE
  * ⌘L while Chromium owns focus (menu key equivalent -> address field focus)
  * ⌘L select-all followed by typing replacing the selection
  * clicking the page after using the address field returns typing to the page
  * Chinese IME composition in the address field (candidate window, commit)
  * Back/Forward/Reload/Stop button enablement as drawn on screen
  * Escape cancelling an unsubmitted address edit
  * window resize behaviour of the Chromium content below the new toolbar
See the Milestone 2 manual checklist (Tests A-K) in the session report.
```

## Compatibility checklist 3

```text
REQUIRES MANUAL VERIFICATION (not covered by this script):
  TEST A  launch: one visible tab, Google/default home loads, toolbar works
  TEST B  Cmd+T four times: five tabs, each with its own browser, newest selected;
          navigate them to different pages and check each keeps its own URL
  TEST C  switch repeatedly: no reload, no white recreation flash, no new browser
  TEST D  independent history: 3 pages in one tab, 2 in another; Back/Forward
          state belongs to the selected tab only
  TEST E  type but do not submit in Tab A; let a background tab navigate; Tab A's
          edit buffer must survive; switching to Tab B shows Tab B, and back again
  TEST F  Cmd+L with Chromium focused in several tabs: only the selected tab's
          field focuses and selects all; Chinese IME composition stays normal
  TEST G  Cmd+W on a selected middle tab: only that tab closes, the neighbour is
          selected, the window stays open, the other browsers stay alive, and
          typing reaches the neighbour without an extra click (the hand-over of
          AppKit focus itself is automated as selected-close-transfers-focus)
  TEST H  close a background tab with the sidebar button: the active page keeps
          keyboard focus and is not blurred (automated as
          background-close-keeps-focus; that a keystroke still reaches the page
          afterwards is manual)
  TEST I  reduce to one tab, Cmd+W: a fresh usable tab is created, window stays
  TEST J  close a tab with a distinctive URL, Cmd+Shift+T: new tab, same URL, new
          runtime identity, selected
  TEST K  target=_blank: managed new tab, no unmanaged Chromium window, the
          current tab is not replaced
  TEST L  ~20 tabs: navigate, switch rapidly, close in mixed order - no crash, no
          duplicate browser, no stale toolbar
  TEST M  Cmd+Q with >=5 tabs, once with page focus and once with address-field
          focus: clean exit, no five-second fallback, all browsers OnBeforeClose,
          CefShutdown only after, no residual process. Record with
          --log-shutdown-timing and check with Scripts/check_shutdown_timing.py
  TEST N  red window close button with several tabs: shutdown stays clean
  TEST O  resize rapidly while switching tabs: the selected surface always matches
          the available bounds

  Milestone 3 focus ownership (real key events; the ownership rules themselves
  are automated in --tabs-self-test and listed as pass lines above):
  TEST P  page focused, Cmd+T, immediately type: the hidden tab receives no input
          and the new tab owns page focus once its browser exists
  TEST Q  press Cmd+T several times and click among tabs while pages are still
          being created: a late OnAfterCreated from a hidden tab never steals
          focus (the same race without key events is automated as
          late-browser-creation-keeps-focus)
  TEST R  address field focused, then switch tabs or create one: keyboard focus
          does not jump to a hidden or newly created Chromium browser
  TEST S  Cmd+L + Chinese IME after several tab switches: composition, candidates
          and commit stay normal
```

## Compatibility checklist 4

```text
REQUIRES MANUAL VERIFICATION
  - click between Spaces and confirm the one visible Chromium surface follows selection
  - type into the address field, switch Spaces, and confirm text/focus are preserved
  - use Cmd-T/Cmd-W/Cmd-Shift-T and Cmd-1…Cmd-9 in multiple Spaces
  - rename a Space and confirm empty names are rejected
  - open a real target=_blank popup from an inactive Space and inspect its destination
```

## Current shell and glass checks

REQUIRES MANUAL VERIFICATION:

- One shell backdrop; toolbar/rail 56 pt, Main View edge insets 4 pt and corners 14 pt.
- Native traffic lights centered using their actual size; equal red-button top/left inset.
- Sidebar glass circle 36 x 36 pt; continuous navigation capsule 72 x 36 pt in its 74 pt host.
- Material outlines and native hover/press/disabled feedback in single and split pages.
- Sidebar collapse/expand and 1→2, 2→3, 3→2 splits preserve mounted controls/editors.
- Interrupted page/control movement continues; toolbar materializes in the page handoff transaction.
- Current Cmd-T Spotlight flow, Cmd-L/R/[/], Return/Escape, Chinese IME and page/address focus.
- Real Cmd-Q with page/address focus, typed OnBeforeClose before one CefShutdown; inspect timing logs.
