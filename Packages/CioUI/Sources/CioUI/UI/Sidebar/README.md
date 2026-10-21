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

`SidebarRowMotion` uses a SwiftUI affine geometry effect for container position;
only actual size changes and Pin reveal opacity use custom interpolation in
the animation package. Each retained surface, decoration and member receives
the same local transaction after the GeometryReader resolves its destination;
native-control opacity rules cannot cancel container movement. Divider and
New Tab use this exact path. `SidebarPanelHeightMotion` interpolates occupied
height too, so Top Pin reservations continuously displace the Space header and
viewport. Unchanged frame destinations do not restart motion.
The inner GeometryReader stays at the target height while the outer occupied
height animates, anchored at the top. Presentation-height samples must not flow
back into destination calculation or rebuild every retained tab on every frame.

Tab titles keep regular weight, including the stable selection. Idle titles use
the full row width; only hovering a row reserves room for its retained close
button. The close icon uses the address reload control's scale, color and timing
feedback without resizing its hit area. Space rows and Top Pins share the 5pt
outer content inset, matching the Space row gap.
Split members use the same close button width and trailing inset as ordinary
tabs, aligning the rightmost close icons across single and grouped rows.

Space rows have the same 36pt height and 5pt gap, including divider/New Tab rows
and empty drop targets. Top Pins use the same flat panel with their grid columns,
40.5pt height and 9pt spacing. An empty Space Pin tier reuses the divider's upper
half as its drop target; a full-height gap appears only while a drag targets it.

Stable tabs retain their native glass, and Top Pins retain their idle fill,
hover border and selected scale. A selected split has one shared native glass
surface behind its retained member controls; Top Pin groups retain their outer
idle fill. Combined members have no nested fills or glass. Non-Top-Pin groups
have no idle fill; hovering either member highlights the entire group with the
same surface as an ordinary tab. Native vertical `Divider`s separate members. The group
surface is a separate background layer so glass never overlays the native tab
labels or intercepts their controls. The foreground decoration adds the existing
hover ungroup control. Sidebar pickup uses the resting tab's retained label,
regular weight, icon grid, compact member geometry and native separators.
The floating surface applies one native glass effect around its label, keeping
the label in the effect's foreground and letting the system draw its sole edge.
It hands off immediately without materializing, fading or scaling the object;
only elevation changes. Selected Top Pins retain their existing selection scale.
Pane-to-card flights retain their separate page morph and lift treatment.

`SidebarTabDrag` coordinates lifting, targeting, autoscroll and landing. A split
supplies one draggable row; registered divider/New Tab/footer frames define tier
drop regions. The original lifted member IDs are captured at drag start: a split
commit cannot accidentally hide the existing members of the destination group.
While the pointer remains inside its registered reservation, that reservation
owns the drop boundary, in ordinary Space lists, overview columns and Top Pins.
Animated neighbours and dividers cannot reverse its flight or change its tier;
leaving the reservation resumes targeting immediately without a timed debounce.
An old gap from another tier cannot retain the new target.
Sidebar split entry captures the page reveal duration and curve, while ordinary
reorders use the named Sidebar motion. Dropping on the browser retains the
existing split-preview callbacks.

Native webpage-link drops use `BrowserWebPageDropView`. Dropping into the Space
tab list creates an unpinned background tab at the indicated row boundary and
keeps the displayed tab stable. Hover reserves the same animated row gap as an
incoming split pane; commit replaces the gap without moving its neighbours.
The browser's rightmost fifth previews and adds
a new right pane; a three-pane group rejects this drop without replacing pages
or creating a leftover tab. The trigger uses committed browser bounds even
during preview compression and requires 48 pt of rightward movement from the
mouse-down position (first entry for external drags). Preview only animates the
outer crop: Chromium retains its committed size through cancellation and is
resized once when a split commits. Other browser regions retain native Chromium drag
behavior. The normal native link drag image hands off to the shared page reveal
and toolbar clock when the split commits.

Haptic feedback belongs to the containers. `SpaceTabPanel` compares logical tab
slots and emits native alignment feedback when a reservation or reorder moves
existing controls. `BrowserSurfaceHostView` emits alignment for split compression
and pane reordering, and level-change feedback for replacement. Input coordinators
only choose destinations; native webpage links and sidebar cards share the same
feedback path. Repeated layout ticks, title/focus updates, slots that do not move
existing controls and reservation cleanup do not repeat feedback.

Space Pin collapse still snapshots the hidden tab IDs. Selecting another tab
does not change that snapshot, and newly pinned tabs remain visible. Command-D
and the context menu share the row move/landing path; Command-S uses the native
sidebar toggle.
Hidden pins keep their native controls mounted in their original row order above the panel without reserving
row space or participating in hit testing, accessibility or drag registration.
Collapse first moves them upward, then fades them near the header; expansion reverses that path downward,
while the divider and following rows reflow on the same clock. The retained
disclosure chevron rotates between right and down. Both effects use
`AnimationValues.Sidebar.spacePinToggleDuration`, respect the speed setting and
skip motion under Reduce Motion. `SidebarRowMotion` derives opacity from
the interpolated reveal clock so the header's spatial fade and tab opacity do
not erase the visible movement in the first half of the flight.

Space and Tab rows share `SidebarRowContainer`, `SidebarRowLabel` and
`SidebarRowActionSymbol`: the same icon bounds, title origin, trailing action
center, 29pt hit slot and 3pt trailing inset. Space changes the title weight and
supplies disclosure/menu actions. Native menus use the plain button style so
platform menu padding cannot shift the shared action center. Emoji fit their
actual glyph into the icon bounds, and SF Symbols preserve their aspect ratio.

The Space header's primary button fills the row, so clicking its title or empty
space toggles collapse as well as clicking the leading icon. The trailing menu
remains an independent control. During Tab dragging, the header blocks activation
while keeping its icon and title at their resting appearance. The leading icon
slot shows disclosure: expanded headers show the configured emoji/SF Symbol at
rest and a down chevron on hover;
collapsed headers always show a right chevron. Hover reveals the trailing native
menu, whose only command is Change Space Icon. The native popover offers Emoji
categories/search and an SF Symbol grid. Reset restores the default icon. The
header and footer indicator read the same live Space metadata.

`BrowserSpace.metadata` contains personalization. `SpaceMetadataStore` writes
names and icons to `space-metadata-v1.json`, independently of the tab-only
`session-v1.json` projection. SessionStore joins the files by Space UUID and
migrates legacy embedded names/icons before removing their session copy.
Metadata has its own recovery copy and survives tab-session backup recovery;
damaged metadata never invalidates the tab graph. Future Space colors belong
in BrowserSpaceMetadata and this metadata file.

Animation tuning lives in `Packages/CioUI/Sources/CioUI/Animation/`, under
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
