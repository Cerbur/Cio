# Build and validate NativeBrowser

- Always build the app from the repository root with `CONFIGURATION=Debug Scripts/build.sh`. The script regenerates the Xcode project and keeps DerivedData under this repository's `build/` directory. Do not use a separate `xcodebuild` app build or an external DerivedData directory.
- For subsequent changes, validation defaults to running the build script above. If the build completes successfully with no compilation errors, deliver the changes to the user; no additional validation or app launch is required by default.
- Use computer use for validation only when the user explicitly requests it. In that case, open the resulting Debug app at `build/DerivedData/Build/Products/Debug/NativeBrowser.app` and make sure an already running NativeBrowser instance is not reused in place of this freshly built app.
- For explicitly requested computer-use checks, resolve `build/DerivedData/Build/Products/Debug/NativeBrowser.app` relative to the repository root and connect to that Debug app, not by the generic NativeBrowser app name. Verify the inspected window belongs to the freshly built instance.

# Required shell layout constraints

These are user-defined constraints from [the layout session](codex://threads/01a0f0a4-00f0-7101-9eee-4b1e0b1ed7ec). Preserve them when fixing interactions or changing components; change them only when the user requests a layout change.

- A single `backgroundGlass` backdrop fills the entire shell. Toolbar, Main View and Navigation Rail sit above it.
- Toolbar height and Navigation Rail width must use the same `BrowserLayout.chromeThickness` constant, currently **56 pt**. Do not add titlebar, safe-area or padding offsets that make their effective thickness differ.
- All toolbar controls, including the traffic lights, must be vertically centered within the toolbar. The red close button's left inset from the shell edge must equal its top inset. Derive both from the toolbar height and the button's actual size: `(toolbarHeight - buttonHeight) / 2`. Restoring the system's default titlebar position does not satisfy this requirement if the buttons cease to be centered in the toolbar.
- Toolbar controls follow the Main View's current section. Space shows the sidebar button, address field and navigation controls; section changes must preserve the shared toolbar geometry and traffic-light alignment.
- Main View fills the remaining area after the toolbar and Navigation Rail, with rounded clipping. Its top offset equals the shared chrome thickness; its left offset equals that thickness when the Space sidebar is collapsed. An expanded sidebar occupies additional horizontal space. Right and bottom insets must remain equal, using `BrowserLayout.mainViewEdgeInset`, currently **4 pt**.
- Main View, Tab and Top Pin must share `BrowserLayout.contentCornerRadius`, currently **14 pt**.
- Keep these dimensions centralized in `NativeBrowser/UI/Main/BrowserShellLayout.swift`. Visual balance between the shell's upper-left curve, red button, Main View and Top Pin corners must result from the shared dimensions and insets, not from hard-coded diagonal alignment or separate corrective offsets.

# Native component implementation

- Prefer native AppKit or SwiftUI components, system styles, materials and SF Symbols for every UI component. Do not hand-draw replacements for components or interactions provided by the system.
- Traffic lights must use the window's native close, minimize and zoom buttons, preserving system hover glyphs, activation, accessibility and button actions. Do not substitute custom circles, custom glyphs or imitation hover behavior.
- Native behavior and the layout constraints above must both be satisfied. Do not silently relax spacing or alignment to fix hover, dragging or another interaction, and do not replace native behavior with custom drawing to preserve the layout.

# Animation parameters

- `NativeBrowser/Animation/` is the dedicated animation package, compiled into the existing app target. Keep shared motion implementations and preferences here; split tuning files by effect / component, extending the single `AnimationValues` namespace (for example `AnimationValues.SplitPages` or `AnimationValues.Toolbar`).
- All new or modified custom window / UI animation effects must declare their tuning in this package. Do not write animation durations, delays, spring responses, damping, easing control points, speed multipliers or animation-specific scale / progress values directly in component files. Components must reference named `AnimationValues` properties.
- Declare base timings at the Standard pace in the corresponding `*AnimationValues.swift` file. Resolve time values through `AnimationValues.duration(_:)`, which multiplies them by the persisted Settings speed ratio. Returned timings are already scaled: do not multiply again or cache them in a `static let`. Curves, damping and geometry stay independent of speed.
- Animation-related handoff, retention and cleanup waits must also use named timing values and the same speed ratio. Capture the timing when a flight starts if later stages must stay on its clock; prefer completion callbacks over unrelated timers.
- Preserve Reduce Motion behavior and system-owned native animation. Input debounce, Chromium scheduling, frame polling and pointer-driven scrolling are operational timing, not visual animation speed; do not scale them with the animation preference.
- See `NativeBrowser/Animation/README.md` for the package layout and usage examples.

# Liquid Glass component motion contract

- Apply the shared template in `NativeBrowser/Animation/GlassComponentVisibility.swift` and `GlassComponentLayoutMotion.swift` to first-level glass components (for example the sidebar button, shared Back/Forward capsule and address capsule). See `NativeBrowser/Animation/GLASS_COMPONENT_MOTION.md` for the reference and Apple documentation.
- Appearance must converge inward from a dispersed, blurred state into a solid, sharp component. Disappearance must disperse outward from the solid component into a blurred state. Use the system's native Liquid Glass `materialize` transition for the material; opacity/scale alone does not satisfy this requirement. Keep the glass container mounted for both directions and animate content blur/opacity separately, without fading the glass's parent to zero or adding imitation glass.
- Any component position change must move continuously to its target. Size increases must overshoot outward and settle back; size decreases must undershoot inward and spring back. Use the system Spring with named parameters from `AnimationValues.GlassComponent`, following Spotlight's spring-based expansion. Position must not bounce merely because size bounces.
- Retarget an interrupted movement from the current presentation geometry and velocity. Repeated layout notifications and page-flight completion must not restart or truncate a component flight whose destination is unchanged.
- During split previews and 1→2, 2→3, 3→2 switches, surviving components reflow without disappearing; outgoing components disperse at their last visible position; incoming components materialize once concurrently with their page reveal, sharing its captured duration and curve. Keep them hidden until the drag/card handoff, mount and lay out the hidden hosts before the visibility transaction, then start page and toolbar in the same handoff transaction. Reveal completion only cleans up; it must not trigger a delayed toolbar appearance. Never show→hide→show a toolbar in one handoff.
- Keep native controls/editors mounted to preserve focus, actions, enabled states, hover/press feedback and accessibility. Apply first-level motion once, not recursively to symbols or text. Window traffic lights retain system-owned behavior. A normal single-page tab switch keeps the existing immediate toolbar-slot replacement policy.
- Native materialize and Spring are Apple APIs; overshoot, blur and timing values are this project's explicit visual requirements, not Apple-mandated constants. Keep all tuning, speed scaling, cleanup clocks and Reduce Motion behavior in the animation package.
