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
