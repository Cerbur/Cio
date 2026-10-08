# CioEngine interface and current callers

The protocols refer to the existing App objects. No navigation/workspace state is copied, and no relay publisher, queue, Task, close coordinator or Chromium dependency is added. The App retains BrowserSession/BrowserSessionManager, concrete typed close callbacks, the runtime registry and all native Chromium lifetime policy. The UI never needs CloseBrowser or a close callback: it calls the existing workspace closeTab operation. Original default-argument conveniences forward to full protocol requirements.

## BrowserSessionProtocol

| Member | Existing caller |
| --- | --- |
| objectWillChange | SwiftUI session consumers in TabFaviconView and ToolbarAddressFieldView, via ObservedEngine using the original publisher |
| id | ToolbarAddressFieldView.onChange: runtime replacement ends completion |
| tabID | BrowserToolbarController.isActive/activatePane; BrowserWorkspaceStore.refreshTabMetadata/openPopupInNewTab |
| title | BrowserWorkspaceStore.refreshTabMetadata |
| url | ToolbarAddressFieldView, TabFaviconView, BrowserToolbarController; workspace metadata |
| faviconURLs | TabFaviconView |
| isLoading | ToolbarAddressFieldView reload/stop; BrowserToolbarController site-information dismissal; workspace metadata |
| canGoBack | BrowserToolbarController.bindSession initial state |
| canGoForward | BrowserToolbarController.bindSession initial state |
| rendererCrashed | BrowserMainViewController recovery view; BrowserToolbarController; split readiness |
| hasFinishedFirstLoad | BrowserSplitPageTransition.beginGlass: first-content handoff |
| siteInformation | BrowserToolbarController certificate/popover actions |
| engineAddressField | AddressField and ToolbarAddressFieldView receive the original AddressFieldModel |
| ownsPageKeyboard | BrowserWorkspaceStore.withSelectionTransition/commitTabClose |
| isEditingAddressField | BrowserWorkspaceStore.withSelectionTransition |
| canGoBackPublisher | BrowserToolbarController.bindSession CombineLatest |
| canGoForwardPublisher | BrowserToolbarController.bindSession CombineLatest |
| urlPublisher | BrowserToolbarController.bindSession dismisses stale site information |
| isLoadingPublisher | BrowserToolbarController.bindSession retains the original willSet/main-queue handoff |
| lastErrorCodePublisher | BrowserToolbarController.bindSession error/crash CombineLatest |
| rendererCrashedPublisher | BrowserToolbarController.bindSession and BrowserSplitPageTransition readiness |
| hasFinishedFirstLoadPublisher | BrowserSplitPageTransition.beginGlass, with its original operators/clock |
| load | ToolbarAddressFieldView.submit completion; BrowserWorkspaceStore.loadInSelectedTab |
| reload | BrowserMainViewController renderer-crash recovery |
| reloadOrStop | BrowserToolbarController.handle(addressReloadOrStop) |
| goBack | BrowserToolbarController native navigation action |
| goForward | BrowserToolbarController native navigation action |
| focusPage | BrowserToolbarController/ToolbarAddressFieldView and workspace selection transition |
| blur | BrowserToolbarController visibility handoff and workspace selection transition |
| addressFieldFocusChanged | BrowserToolbarController.handle(addressFocusChanged) |
| submitAddressField(searchEngine:) | ToolbarAddressFieldView native Return submission; no-argument convenience uses the original GoogleSearchEngine |
| cancelAddressEditing | ToolbarAddressFieldView native Escape action |
| releaseFocusBeforeTabRemoval | BrowserWorkspaceStore.commitTabClose before domain removal |

NavigationState remains the existing pure snapshot returned by the concrete App session. It moves into Engine with unchanged fields/defaults; it is not an unused requirement on the UI protocol. BrowserDownloadUpdate and SiteInformation are engine-independent translated values. Download identifiers remain scalar correlation values, never native browser objects.

## BrowserAddressEditing

| Member | Existing caller |
| --- | --- |
| objectWillChange | AddressField and AddressCompactText observe the original model |
| committedURL | AddressField focus/display; ToolbarAddressFieldView |
| editText | AddressField native editor; ToolbarAddressFieldView submission |
| isEditing | AddressField deferred focus identity check |
| userChangedText | ToolbarAddressFieldView onTextChange |
| endEditing | ToolbarAddressFieldView.submit |
| compactDisplayText | AddressCompactText |

The concrete model stays UI. App-only applyBrowserURL/cancelEditing/displayText and placeholder remain on that same model; they are not added to the Engine protocol.

## BrowserWorkspaceProtocol

| Member | Existing caller |
| --- | --- |
| objectWillChange | TabSidebarView/SpaceTabPanel, ToolbarAddressFieldView, BrowserMainViewController views and BrowserToolbarController |
| spaces | TabSidebarView Space rows; BrowserMainViewController empty-workspace selection |
| selectedSpaceID | TabSidebarView and SpaceTabPanel selected identity |
| selectedSpace | TabSidebarView current Space presentation |
| selectedTabID | BrowserToolbarController pane activation; sidebar selection; BrowserSurfaceHostView click selection |
| globalPinnedTabs | TabSidebarView top pins |
| activeSplit | TabSidebarView, BrowserMainViewController split/drop geometry |
| isSpotlightPresented | ToolbarAddressFieldView and BrowserSurfaceHostView visibility/focus gates |
| isSpotlightPresentedPublisher | CioShellController, original receive(on: RunLoop.main) |
| engineSelectedSession | BrowserToolbarController selected-session binding; BrowserMainViewController recovery; workspace navigation/focus policy |
| browserSession(for:) | TabSidebarView/SidebarTabPresentation/ToolbarAddressFieldView per-tab metadata |
| tab(withID:) | Sidebar drag/row actions and per-page toolbar |
| splitGroup(containing:) | Sidebar group/drag actions |
| createSpace(name:) | TabSidebarView new-Space action; convenience passes nil |
| renameSpace(id:name:) | SpaceTabPanel native rename field |
| selectSpace(id:) | TabSidebarView Space selection |
| selectTab(id:focusingPage:) | Sidebar and pane selection; convenience preserves false |
| closeTab(id:) | Sidebar close action and BrowserPagePresentation split control |
| clearTemporaryTabs(in:) | SpaceTabPanel clear action |
| presentSpotlight | TabSidebarView/SpaceTabPanel new-tab action |
| loadInSelectedTab | HistoryPanelView open-in-current-page action |
| moveTab(_:to:before:) | BrowserMainViewController/TabSidebarView tier drop and pin operations |
| moveSplitGroup(containing:to:before:) | BrowserMainViewController grouped drag |
| spacePinToggleTarget(for:) | TabSidebarView pin notification |
| canSplit(with:) | BrowserMainViewController drop eligibility |
| splitTab(_:at:) | BrowserMainViewController split drop |
| detachSplitPane(_:selectDetached:) | BrowserPagePresentation split controls |
| moveSplitPane(_:to:before:) | BrowserMainViewController collapse/drop; App forwards to the original SidebarTabDropTarget overload |
| reorderSplitPane(_:to:) | BrowserMainViewController pane drag |
| setSplitFraction(_:divider:) | BrowserSurfaceHostView retained divider callback |
| ungroupSplit(containing:) | TabSidebarView group context menu |
| swapSplitSides(containing:) | TabSidebarView group context menu |

Surface drag/animation APIs belong to the UI injection seam, not Engine. App-only startup, persistence flush, termination, liveness and close acceptance/cancellation APIs remain concrete. Engine's history/session/download/autocomplete implementations move with their original algorithms and original Runtime-owned instances because UI already consumes those services directly.
