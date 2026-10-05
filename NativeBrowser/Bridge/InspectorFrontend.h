#pragma once

// Shared with the renderer helper. These exact URLs are the only documents
// allowed to use the inspector's privileged, tab-local transport.
inline constexpr char kInspectorURL[] =
    "devtools://devtools/bundled/devtools_app.html?can_dock=true&panel=elements";
inline constexpr char kEmulationURL[] =
    "devtools://devtools/bundled/device_mode_emulation_frame.html?can_dock=true&panel=elements";
inline constexpr char kInspectorMessage[] = "NativeBrowser.Inspector";
