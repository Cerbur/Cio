# Chromium accessibility, media and debugging

Cio uses native Chromium 152 through its Objective-C bridge. Chromium supplies
macOS accessibility for page content; the shell keeps native AppKit/SwiftUI
controls. The retired CEF backend and its setup, codec and packaging scripts
are no longer present. Current engine configuration and limitations are in
[the engine guide](../Engine/Chromium/README.md).

## Web Inspector

Use **Develop → Show Web Inspector** or **⌥⌘I** for the selected page.
The bundled Chromium DevTools frontend is hosted in Cio's native inspector
container. It is currently restricted to docking; it does not create a separate
Chromium browser window. Elements displays the inspected page's DOM and CSS.
Closing the inspector restores the page, and closing a tab closes its inspector.
The bridge manages frontend WebContents through Chromium's DevToolsWindow;
there is no separate CEF client or custom JavaScript protocol transport.

Normal launch does not request a remote debugging listener. The old
`CIO_CDP_PORT` environment-variable adapter belonged to CEF and has been removed;
it is not an entry point for the native backend. Embedded DevTools uses
Chromium's own internal transport.

## Media

The pinned native build enables `proprietary_codecs=true`, Chrome FFmpeg branding
and platform HEVC. During the 2026-10-08 computer-use acceptance, local H.264 and
H.265 videos both decoded and played through two seconds inside Cio. MIME
support alone is not a playback test, and these two fixtures do not establish
support for every codec profile, streaming service or DRM system. This build
does not include Widevine or private Google service integrations.

Changing user-agent strings cannot add codecs. Rebuilding or upgrading the
engine uses `Scripts/try_chromium_build.py` and the required repository app build:

```sh
CONFIGURATION=Debug Scripts/build.sh
```

Updates require the pinned source and overlay to match, the complete native
runtime and its license notices to be replaced, and playback to be rechecked.
This is an independently maintained engine build, not a hot-swappable stock
Chromium binary. See [source and reuse notices](../THIRD_PARTY_NOTICES.md).

## Verification

```sh
Scripts/verify_bundle.sh
# Explicit test keychain; isolated temporary data, not the user's profile.
Scripts/verify_runtime.sh --mock-keychain
```

The native runtime driver verifies normal load/quit, page rendering, Chrome
Settings, repeated load/shutdown and both beforeunload branches. GUI and media
acceptance remain separate from static compilation. Under the repository's
validation policy, subsequent source cleanup defaults to the required Debug
build and does not automatically launch the application.
