# Space Tab panel

`SpaceTabPanelRow` projects a Space into one ordered row sequence. A row
contains tab elements (one tab or a split pair), New Tab, a divider, or a
structural drop gap. Row identity is independent of pin/temporary membership.

`SpaceTabPanel` flattens native tab controls into one `ForEach`, keyed by each
individual tab UUID. Structural rows register whole-row drag geometry and draw
only dividers, New Tab and drop gaps. `SidebarTabPanelLayout` maps the retained
controls to their row/member destinations. Joining, leaving, or swapping a split
changes frames and interpolated label geometry without replacing a tab's select
button, close button, favicon or title. Focus/title changes do not restart layout
motion; ordered member IDs are part of the destination so pane swaps animate.
Moving between Space Pin and Temporary also retains the same controls.
Dimensions come from `BrowserShellLayout.swift`.

Space rows have the same 36pt height and 5pt gap, including divider/New Tab rows
and empty drop targets. Top Pins use the same flat panel with their grid columns,
40.5pt height and 9pt spacing. An empty Space Pin tier reuses the divider's upper
half as its drop target; a full-height gap appears only while a drag targets it.

Stable tabs retain their native glass, and Top Pins retain their idle fill,
hover border and selected scale. A selected split has one shared native glass
surface behind its retained member controls; Top Pin groups retain their outer
idle fill. Combined members have no nested fills or glass. Non-Top-Pin groups
have no idle fill; native vertical `Divider`s separate members. The group
surface is a separate background layer so glass never overlays the native tab
labels or intercepts their controls. The foreground decoration adds the existing
hover ungroup control. Lifting a stable tab/group preserves its glass continuity;
other floating cards materialize their glass.

`SidebarTabDrag` coordinates lifting, targeting, autoscroll and landing. A split
supplies one draggable row; registered divider/New Tab/footer frames define tier
drop regions. The original lifted member IDs are captured at drag start: a split
commit cannot accidentally hide the existing members of the destination group.
Sidebar split entry captures the page reveal duration and curve, while ordinary
reorders use the named Sidebar motion. Dropping on the browser retains the
existing split-preview callbacks.

Space Pin collapse still snapshots the hidden tab IDs. Selecting another tab
does not change that snapshot, and newly pinned tabs remain visible. Command-D
and the context menu share the row move/landing path; Command-S uses the native
sidebar toggle.

Animation tuning lives in `NativeBrowser/Animation/`, under
`AnimationValues.Sidebar` and `AnimationValues.TabDrag`. Timing properties
already apply the Settings speed ratio. New effects must reference these named
values rather than embedding durations, delays, spring response or damping in
the panel / tab components. See the animation package README and root AGENTS.md.

Pane minimize reserves the destination under its final `.tab` identity at the
start of the collapse, before durable split membership changes. The hidden tab
controls are already mounted behind the drop slot; following rows (including
divider/New Tab) move with the collapse's captured duration and curve. The
midpoint updates the source group's contents while retaining both container
identities and all row indices. Layout animation watches row identities and ordered member IDs rather than
focus/title changes, so midpoint notifications do not restart list movement.
Landing reveals the mounted tab with the same label layout as the flying label.
The native page/glass flight and survivor expansion use the captured clock;
generic drag frame-wait timeouts cannot truncate a minimize flight. Top Pins
use the same reservation projection with their grid geometry.
