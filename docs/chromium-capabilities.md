# Chromium accessibility, compatibility and debugging

Every windowed page explicitly enables CEF accessibility in Complete mode.
Chromium supplies the native macOS accessibility objects for page text, links,
controls and frames without requiring VoiceOver or a synthetic DOM-to-AX bridge.

The UA product is `Chrome/<bundled Chromium major>.0.0.0`. Chromium generates
the remaining desktop UA tokens and UA Client Hints. Changing this identity
does not add codecs or DRM support.

Use **Develop → Show Web Inspector** or **⌥⌘I** for the selected page. The real
Chromium frontend opens in a bottom pane inside Main View. Drag the native
split divider to resize it; repeating the shortcut closes the inspector and
restores the full page height. Each tab owns its inspector and split position,
so switching tabs preserves both the page and inspector sessions.

The inspector uses a separate CEF client and an application-owned child view,
so its navigation and close callbacks cannot change the page or close the shell
window. Closing a page closes its inspector too. Runtime ownership is retained
until both browsers deliver OnBeforeClose, including during app termination.
Outer shell thickness, insets and corner clipping are unchanged.

CEF 152's `ShowDevTools()` creates a Chrome-style inspector. On macOS,
`SetAsChild()` forces Alloy style, so combining these APIs hits CEF's fatal
runtime-style check. The docked inspector instead loads the runtime's bundled
`devtools_app.html` as an ordinary Alloy child. A renderer binding restricted
to that explicitly marked browser and exact main-frame URL forwards messages
to `SendDevToolsMessage`; `AddDevToolsMessageObserver` returns results/events.
The binding preserves Chromium's compatibility host when Blink installs it
after CEF's context-created callback. Protocol response IDs are translated so
the shell's appearance commands cannot collide with frontend commands.

The regression check requires the real CEF runtime; the standalone logic-test
target does not link CEF. In a freshly built Debug instance, open with ⌥⌘I,
verify Elements contains the inspected page's DOM/CSS, and execute `1 + 1` in
Console (result `2`). Drag the divider, close/reopen three times, switch away
and back, and quit with the inspector open. Confirm no crash and no TCP debug
listener. A successful compilation alone does not validate this integration.

Debug disables Chromium's `MacAppCodeSignClone` updater feature, following
[Chrome for Testing's rationale](https://chromium.googlesource.com/chromium/src/+/refs/tags/152.0.7977.83/chrome/browser/mac/code_sign_clone_manager.mm).
In a rebuilt ad-hoc bundle its background hard-link operation was observed
blocking CEF shutdown. NativeBrowser has no Chrome auto-update flow. This
switch does not disable macOS signing or signature verification; Release
retains the default. App termination closes the inspector and releases its
protocol registration before tearing down the inspected page.

CDP network debugging is disabled by default, including in Debug builds.
The built-in Web Inspector communicates in-process and needs no open port.
To enable external CDP tools, launch the Debug executable explicitly:

```sh
NATIVEBROWSER_CDP_PORT=9222 build/DerivedData/Build/Products/Debug/NativeBrowser.app/Contents/MacOS/NativeBrowser
```

Then inspect the loopback endpoint:

```sh
curl http://127.0.0.1:9222/json/version
curl http://127.0.0.1:9222/json/list
```

The results expose WebSocket URLs for CDP tools (DOM, Runtime, Network,
Accessibility, screenshots). In Chrome, open `chrome://inspect/#devices` and
configure `localhost:9222`. Choose another port such as
`NATIVEBROWSER_CDP_PORT=9223` if 9222 is occupied. An unset variable or
`NATIVEBROWSER_CDP_PORT=0` leaves the endpoint disabled. Explicit Chromium
`--remote-debugging-port` arguments can also enable it in Debug builds.
Release removes remote debugging port/pipe switches and opens no CDP listener.

## H.264/AAC playback

The standard upstream CEF package disables H.264/AAC. These compile-time
capabilities cannot be restored by a UA change, an HTML5 flag or a replacement
FFmpeg library from another Chromium version. See the [CEF maintainer's
explanation](https://github.com/chromiumembedded/cef/issues/3559).

The codec recipe builds the currently pinned CEF commit and Chromium version
with `proprietary_codecs=true ffmpeg_branding="Chrome"`, using the [upstream
CEF build automation](https://chromiumembedded.github.io/cef/automated_build_setup).
It needs macOS arm64, Xcode, Python 3, network access and a build volume with
at least 200 GiB free. The first build can take hours; subsequent builds reuse
the checkout. The app continues using the standard runtime until this succeeds.

```sh
# Use a sufficiently large volume; the script installs the result and runs
# the app's required Debug build from the repository root.
Scripts/build_cef_codecs.sh /Volumes/BuildSSD/nativebrowser-cef

# Or install an existing full, EXACT-version macOS arm64 CEF distribution:
Scripts/install_cef_runtime.sh /absolute/path/to/cef_distribution
CONFIGURATION=Debug Scripts/build.sh
```

The installer keeps the previous runtime, swaps headers/framework/wrapper
sources together and invalidates wrapper objects. An existing distribution
must actually have codec support compiled in; version and architecture checks
alone do not prove playback. Distribution of proprietary codecs requires
reviewing the applicable licensing terms described by upstream.

After replacing the runtime and restarting the app, check these in DevTools:

```js
({
  userAgent: navigator.userAgent,
  clientHints: navigator.userAgentData?.toJSON(),
  h264: document.createElement('video').canPlayType('video/mp4; codecs="avc1.42E01E"'),
  aac: document.createElement('audio').canPlayType('audio/mp4; codecs="mp4a.40.2"'),
  mse: MediaSource.isTypeSupported('video/mp4; codecs="avc1.42E01E, mp4a.40.2"')
})
```

H.264/AAC should be nonempty and MSE true. Also check actual playback: MIME
support alone does not verify decoding, website authorization or DRM.
