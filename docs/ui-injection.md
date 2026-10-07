# CioUI injection audit

CioUI imports only system frameworks, CioEngine and CioModel. App remains the composition root and owns every CEF object, session, container, bridge and lifecycle callback.

| Boundary | Original operation preserved |
| --- | --- |
| BrowserUIContext | Original Runtime objectWillChange and panel publisher; synchronous property/action forwarding; constructed once |
| ObservedEngine | Original workspace/session/editor/manager object and ObservableObjectPublisher; no state copy, relay, queue or Task |
| BrowserSurfaceDriverProtocol.makeSurfaceHost | makeNSView creates/configures the host, sets covered state, then attaches the original manager |
| BrowserSurfaceView.updateNSView | Re-adopts the same host; existing manager guard and container/session registry stay App-owned |
| BrowserNativeSurface.nativeView | Returns the same ChromiumContainerView; original mount/layout/visibility operations are forwarded |
| BrowserNativeSurface.browserSession | Resolves the existing weak delegate, preserving session ownership |
| BrowserSurfaceAttachment | Transfers only original surface reference, never a new NSView or strong session retention |
| onProcessAppearanceChange | Original CEFProcessHost call runs first, followed by original onDarkAppearanceChange; hook installed before mounting, including bare diagnostic hosts |
| AddressField / CioAddressField | Original NSTextField, field editor, IME delegate and focus callbacks; protocol object is the original AddressFieldModel |
| BrowserCommandNotifications | Original notification names and objects; AppCommands retains native menu equivalents |
| Animation | Original tuning, persisted speed/Reduce Motion policy and handoff/completion order moved with UI |
| SidebarScrollEdge.metal | Original shader bytes processed by SPM; same function resolved in the package resource bundle |

The App-facing public probe/type exports preserve the existing diagnostic switches. Native material outlines, IME/key events and visual transitions remain manual verification; compilation and scripted lifecycle checks do not claim visual verification.
