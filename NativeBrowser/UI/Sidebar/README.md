# Space Tab panel

`SpaceTabPanelRow` projects a Space into one ordered row sequence. A row
contains tab elements (one tab or a split pair), New Tab, a divider, or a
structural drop gap. Row identity is independent of pin/temporary membership.

`SpaceTabPanel` and its row containers own layout, spacing, registration of
drag geometry, source visibility and position animation. All panel rows use
the same layout path, including the divider and New Tab. Moving a tab between
Space Pin and Temporary changes membership without recreating its container.
Dimensions come from `BrowserShellLayout.swift`.
Every container has the same 36pt height and every pair of containers has the
same 5pt gap, including divider/New Tab rows and empty drop targets. The row
model and its elements carry no per-row height or spacing overrides.
An empty pin tier reuses the divider's upper half as its drop target. It adds
no blank container; a full-height gap appears only while a drag targets it.

`SidebarTabDrag` coordinates lifting, targeting, autoscroll and landing. A
split pair supplies one draggable container. Registered divider/New Tab/footer
frames define the pin and temporary drop regions. Top Pins retain their grid
adapter; dropping on the browser retains the existing split-preview callbacks.

`SidebarTabPresentation` passes movement facts to the elements: an ordinary
row, a lifted row, a Top Pin tile, or a detached split-preview card.
`SidebarTabSurface` owns native glass, hover surfaces, material transitions,
lift scale and shadow. Stable tabs retain their existing glass without an
appearance/disappearance transition; Unstable tabs materialize glass while
dragged. The floating container supplies geometry, and the same Tab surface
morphs through the row/tile/card presentations.

Space Pin collapse still snapshots the hidden tab IDs. Selecting another tab
does not change that snapshot, and newly pinned tabs remain visible. Command-D
and the context menu share the row move/landing path; Command-S uses the native
sidebar toggle.

Animation tuning lives in `NativeBrowser/Animation/`, under
`AnimationValues.Sidebar` and `AnimationValues.TabDrag`. Timing properties
already apply the Settings speed ratio. New effects must reference these named
values rather than embedding durations, delays, spring response or damping in
the panel / tab components. See the animation package README and root AGENTS.md.
