//
//  TabSidebarView.swift
//  Cio
//
//  Sidebar blocks: fixed top pin (.global), fixed Space header and scrolling tabs.
//  Space tab contains space pin (.space) and temporary (.temporary) tabs.
//

import CioEngine
import CioModel
import AppKit
import SwiftUI

@MainActor
final class SidebarChromeLayout: ObservableObject {
  @Published private(set) var topInset: CGFloat = 0
  weak var splitView: NSSplitView?
  weak var tabDrag: SidebarTabDrag?
  var onTabDragAvailable: ((SidebarTabDrag) -> Void)?

  func attachTabDrag(_ drag: SidebarTabDrag) {
    tabDrag = drag
    onTabDragAvailable?(drag)
  }

  func update(topInset: CGFloat) {
    guard abs(self.topInset - topInset) > 0.5 else { return }
    self.topInset = topInset
  }

  func resizeSidebar(toWindowX x: CGFloat) {
    guard let splitView else { return }
    let splitOriginX = splitView.convert(.zero, to: nil).x
    let width = min(max(x - splitOriginX + 5,
                        BrowserLayout.sidebarMinimumWidth), BrowserLayout.sidebarMaximumWidth)
    splitView.setPosition(width, ofDividerAt: 0)
    UserDefaults.standard.set(Double(width), forKey: BrowserLayout.sidebarWidthPreferenceKey)
  }
}

@MainActor
private final class SpacePageSwipeState: ObservableObject {
  @Published private(set) var offset: CGFloat = 0
  private(set) var displacement: CGFloat = 0
  private var readyDestinationIndex: Int?

  func scroll(_ delta: CGFloat, selectedIndex: Int, count: Int, width: CGFloat) {
    let atFirst = selectedIndex == 0 && delta > 0
    let atLast = selectedIndex == count - 1 && delta < 0
    let resistance: CGFloat = atFirst || atLast ? 0.22 : 1
    displacement = max(-width, min(width, displacement + delta * resistance))
    offset = displacement

    // Use the release decision so feedback only marks a reachable Space.
    let destination = SpacePaging.destinationIndex(current: selectedIndex, count: count,
      displacement: displacement, width: width)
    let readyDestination = destination == selectedIndex ? nil : destination
    if let readyDestination, readyDestination != readyDestinationIndex {
      BrowserDragHaptics.perform(.spaceSwitchReady)
    }
    readyDestinationIndex = readyDestination
  }

  func reset() {
    readyDestinationIndex = nil
    displacement = 0
    offset = 0
  }
}

private struct SpacePageTrack: View {
  @ObservedObject var swipeState: SpacePageSwipeState
  let selectedIndex: Int
  let pages: [AnyView]
  @State private var outgoingIndex: Int?

  private var firstVisibleIndex: Int {
    max(0, min(selectedIndex, outgoingIndex ?? selectedIndex) - 1)
  }

  private var lastVisibleIndex: Int {
    min(pages.count - 1, max(selectedIndex, outgoingIndex ?? selectedIndex) + 1)
  }

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        ForEach(firstVisibleIndex...lastVisibleIndex, id: \.self) { index in
          pages[index]
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
      }
        .offset(x: -CGFloat(selectedIndex - firstVisibleIndex) * geometry.size.width + swipeState.offset)
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        .clipped()
    }
    .onChange(of: selectedIndex) { oldIndex, _ in
      outgoingIndex = oldIndex
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(AnimationValues.Sidebar.pageRetentionDuration))
        if outgoingIndex == oldIndex { outgoingIndex = nil }
      }
    }
  }
}

struct TabSidebarView: View {
  @ObservedEngine var workspace: any BrowserWorkspaceProtocol
  @EnvironmentObject private var chromeLayout: SidebarChromeLayout
  @State private var pageSwipeState = SpacePageSwipeState()
  @State private var tabDrag = SidebarTabDrag()
  @State private var isSidebarHovered = false
  @State private var isClearHovered = false
  @State private var hoveredNewTabSpaceID: UUID?
  @State private var hoveredTabIDs = Set<UUID>()
  @State private var clearingSpaceID: UUID?
  // Collapse hides a snapshot of the pins outside Stage, not every pin that
  // becomes inactive later. Pins added after that snapshot stay visible.
  @State private var hiddenSpacePinIDs: [UUID: Set<UUID>] = [:]
  @State private var dumpAngle: Double = 0
  @GestureState private var isTabDragGestureActive = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let topPinEdgeInset = BrowserLayout.sidebarContentInset
  private let topPinHeight: CGFloat = 40.5  // 75% of the former 54-point tiles.

  private func columns(for width: CGFloat) -> Int {
    width >= 365 ? 4 : (width >= 275 ? 3 : 2)
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        pinnedGrid(columns: columns(for: geometry.size.width))
          .padding(.horizontal, topPinEdgeInset)
          .padding(.top, chromeLayout.topInset + topPinEdgeInset)
          .onSidebarFrameChange { tabDrag.topPinFrame = $0 }
          .zIndex(1)

        spacePages
          .frame(maxHeight: .infinity)

        footer
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .onHover { isSidebarHovered = $0 }
      .background {
        SidebarGlass()
      }
      // The local scroll monitor receives trackpad swipes before Spotlight's
      // shell overlay handles pointer clicks.
      .background(SpaceSwipeMonitor { delta in
        pageSwipeState.scroll(delta, selectedIndex: selectedSpaceIndex,
                              count: workspace.spaces.count, width: geometry.size.width)
      } onEnd: {
        let next = SpacePaging.destinationIndex(
          current: selectedSpaceIndex,
          count: workspace.spaces.count,
          displacement: pageSwipeState.displacement,
          width: geometry.size.width)
        withAnimation(.smooth(duration: AnimationValues.Sidebar.pagingDuration)) {
          pageSwipeState.reset()
          workspace.selectSpace(id: workspace.spaces[next].id)
        }
      })
      .overlay(alignment: .trailing) {
        SidebarResizeHandle(layout: chromeLayout)
          .frame(width: 10)
          .accessibilityLabel("Resize Sidebar")
      }
      .simultaneousGesture(tabDragGesture(width: geometry.size.width))
      .onGeometryChange(for: CGSize.self, of: \.size) { tabDrag.bounds = CGRect(origin: .zero, size: $0) }
      .coordinateSpace(.named(SidebarTabDragSpace.name))
      .onAppear {
        tabDrag.splitGroupProvider = { [weak workspace] id in workspace?.splitGroup(containing: id) }
        tabDrag.layoutProvider = { [weak workspace, weak chromeLayout, weak tabDrag] in
          guard let workspace, let chromeLayout, let tabDrag else { return nil }
          let space = workspace.selectedSpace
          let globals = workspace.globalPinnedTabs.map(\.id)
          let rightIDs = Set(workspace.spaces.flatMap { $0.splitGroups.flatMap { $0.tabIDs.dropFirst() } })
          let width = max(BrowserLayout.sidebarMinimumWidth, tabDrag.bounds.width)
          let columns: CGFloat = width >= 365 ? 4 : (width >= 275 ? 3 : 2)
          return SidebarTabDragLayout(spaceID: workspace.selectedSpaceID,
            globalTabIDs: globals.filter { !rightIDs.contains($0) }, globalPinnedTabCount: globals.count,
            groupedTabIDs: Set(workspace.spaces.flatMap { $0.splitGroups.flatMap(\.tabIDs) }),
            groupSizes: Dictionary(uniqueKeysWithValues: workspace.spaces.flatMap {
              $0.splitGroups.map { ($0.leftTabID, $0.tabIDs.count) }
            }),
            spacePinTabIDs: (space?.pinnedTabIDs ?? []).filter { !rightIDs.contains($0) },
            temporaryTabIDs: (space?.tabIDs ?? []).filter {
              !(space?.pinnedTabIDs.contains($0) ?? false) && !globals.contains($0) && !rightIDs.contains($0)
            },
            tileSize: CGSize(width: (width - 2 * BrowserLayout.sidebarContentInset
              - BrowserLayout.sidebarTopPinSpacing * (columns - 1)) / columns, height: 40.5),
            topInset: chromeLayout.topInset)
        }
        chromeLayout.attachTabDrag(tabDrag)
      }
      .onReceive(NotificationCenter.default.publisher(for: .browserToggleSpacePin, object: workspace)) { notification in
        if let id = notification.userInfo?["tabID"] as? UUID { toggleSpacePin(id) }
      }
      .onChange(of: isTabDragGestureActive) { _, isActive in
        guard !isActive else { return }
        // Runs after `onEnded`, so only a cancelled gesture is still dragging.
        Task { @MainActor in tabDrag.gestureDidEnd() }
      }
      .onChange(of: reduceMotion, initial: true) { tabDrag.reduceMotion = reduceMotion }
      .onChange(of: spacePinMembership) { _, membership in
        for spaceID in Array(hiddenSpacePinIDs.keys) {
          if let pinIDs = membership[spaceID] {
            // Forget pins that leave so moving them back reveals them too.
            hiddenSpacePinIDs[spaceID]?.formIntersection(pinIDs)
          } else {
            hiddenSpacePinIDs.removeValue(forKey: spaceID)
          }
        }
      }
      .onChange(of: isSidebarHovered) { _, isHovered in
        if !isHovered {
          hoveredNewTabSpaceID = nil
          withAnimation(.easeOut(duration: AnimationValues.Sidebar.clearHoverDuration)) { isClearHovered = false }
        }
      }
    }
  }

  private var selectedSpaceIndex: Int {
    workspace.spaces.firstIndex(where: { $0.id == workspace.selectedSpaceID }) ?? 0
  }

  private var spacePages: some View {
    SpacePageTrack(swipeState: pageSwipeState, selectedIndex: selectedSpaceIndex,
                   pages: workspace.spaces.map { AnyView(spacePage($0)) })
    .onSidebarFrameChange { tabDrag.spaceFrame = $0 }
    .accessibilityIdentifier("space-pages")
  }

  private func spacePage(_ space: BrowserSpace) -> some View {
    let pinnedTabs = visiblePinnedTabs(in: space)
    let globalIDs = Set(workspace.globalPinnedTabs.map(\.id))
    let temporaryTabs = space.tabIDs
      .filter { !space.pinnedTabIDs.contains($0) && !globalIDs.contains($0) }
      .compactMap(workspace.tab(withID:))
    let clearableCount = temporaryTabs.filter { $0.id != workspace.selectedTabID }.count
    let panelRows = SpaceTabPanelRow.make(
      spaceID: space.id, pinnedIDs: pinnedTabs.map(\.id), temporaryIDs: temporaryTabs.map(\.id),
      groups: space.splitGroups, liftedID: tabDrag.sidebarLiftedTabID,
      liftedIDs: tabDrag.sidebarLiftedTabIDs,
      drop: tabDrag.panelDropTarget.map { .init(tier: $0.tier, before: $0.before) },
      paneCollapse: tabDrag.paneCollapse)
    let spotlightIsActive = workspace.isSpotlightPresented && space.id == workspace.selectedSpaceID
    let newTabIsHovered = hoveredNewTabSpaceID == space.id && tabDrag.tabID == nil

    return ScrollView {
      SpaceTabPanel(rows: panelRows, drag: tabDrag) { panelRow in
        panelElement(panelRow, space: space, clearableCount: clearableCount,
                     spotlightIsActive: spotlightIsActive, newTabIsHovered: newTabIsHovered)
      } tabContent: { row, id in
        panelTab(row, id: id)
      } rowBackground: { row in
        groupSurface(row)
      }
      .padding(.horizontal, BrowserLayout.sidebarContentInset)
      .padding(.bottom, 18)
    }
    .scrollIndicators(.hidden)
    .scrollEdgeEffectHidden(true, for: .top)
    .contentMargins(.top, BrowserLayout.sidebarSpaceHeaderHeight, for: .scrollContent)
    .modifier(SidebarScrollEdgeFade())
    // The header stays clear while scrolling rows blur and fade beneath it.
    // Keep the viewport behind the header: an inset would clip the blurred
    // content at the header's bottom before it could reach the fade boundary.
    .overlay(alignment: .top) {
      SidebarSpaceRow(space: space, isCollapsed: hiddenSpacePinIDs[space.id] != nil,
                      isTabDragActive: tabDrag.tabID != nil) {
        withAnimation(reduceMotion ? nil : .smooth(duration: AnimationValues.Sidebar.reorderDuration)) {
          if hiddenSpacePinIDs[space.id] != nil {
            hiddenSpacePinIDs.removeValue(forKey: space.id)
          } else {
            let stageID = space.id == workspace.selectedSpaceID ? workspace.selectedTabID : space.selectedTabID
            let stageIDs = Set(stageID.map { workspace.splitGroup(containing: $0)?.tabIDs ?? [$0] } ?? [])
            hiddenSpacePinIDs[space.id] = Set(space.pinnedTabIDs).subtracting(stageIDs)
          }
        }
      } onRename: {
        promptRename(space)
      }
      .padding(.horizontal, BrowserLayout.sidebarContentInset)
      .padding(.top, BrowserLayout.sidebarTopPinSpacing)
      .padding(.bottom, BrowserLayout.sidebarSpaceHeaderSpacing)
      .onSidebarFrameChange { frame in
        if space.id == workspace.selectedSpaceID { tabDrag.spaceHeaderFrame = frame }
      }
    }
    .coordinateSpace(name: SidebarScrollEdge.coordinateSpace)
    .modifier(SidebarTabDragAutoscroll(drag: tabDrag, isActive: space.id == workspace.selectedSpaceID))
  }

  @ViewBuilder
  private func panelElement(_ container: SpaceTabPanelRow, space: BrowserSpace,
                            clearableCount: Int, spotlightIsActive: Bool, newTabIsHovered: Bool) -> some View {
    if let group = container.splitGroup {
      groupDecoration(group, members: container.tabIDs, tier: container.tier)
    } else if container.elements == [.divider] {
      dividerElement(in: space, clearableCount: clearableCount)
    } else if container.elements == [.newTab] {
      newTabElement(in: space, spotlightIsActive: spotlightIsActive, newTabIsHovered: newTabIsHovered)
    } else if container.id == .gap(space.id) {
      SidebarTabDropSlot()
    } else {
      Color.clear.allowsHitTesting(false)
    }
  }

  private func dividerElement(in space: BrowserSpace, clearableCount: Int) -> some View {
    HStack(spacing: 8) {
      VStack(spacing: 0) { Divider() }
        .frame(maxWidth: .infinity)
      if clearableCount > 0 && (isSidebarHovered || clearingSpaceID == space.id) {
        Button {
          animateClear(in: space.id)
        } label: {
          ClearTrashIcon(isLidOpen: isClearHovered,
                         dumpAngle: clearingSpaceID == space.id ? dumpAngle : 0)
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Clear")
        .help("Close idle tabs except the active tab")
        .allowsHitTesting(clearingSpaceID == nil)
        .onHover { isHovered in
          withAnimation(.easeOut(duration: AnimationValues.Sidebar.clearHoverDuration)) { isClearHovered = isHovered }
        }
      }
    }
    .frame(maxHeight: .infinity)
    .padding(.horizontal, 9)
    .modifier(SidebarScrollEdge())
  }

  private func newTabElement(in space: BrowserSpace, spotlightIsActive: Bool, newTabIsHovered: Bool) -> some View {
    Button {
      workspace.selectSpace(id: space.id)
      workspace.presentSpotlight()
    } label: {
      Label("New Tab", systemImage: "plus")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .contentShape(SidebarTabAppearance.glassShape)
        .modifier(SidebarScrollEdge())
    }
    .buttonStyle(.plain)
    .foregroundStyle(spotlightIsActive ? Color.primary : Color.secondary)
    .modifier(SidebarTabSurface(isStable: spotlightIsActive, isHovered: newTabIsHovered))
    .onHover { isHovered in
      if isHovered {
        hoveredNewTabSpaceID = space.id
      } else if hoveredNewTabSpaceID == space.id {
        hoveredNewTabSpaceID = nil
      }
    }
    .help("Open Spotlight to create a tab")
    .accessibilityAddTraits(spotlightIsActive ? [.isSelected] : [])
  }

  private func animateClear(in spaceID: UUID) {
    guard clearingSpaceID == nil else { return }
    clearingSpaceID = spaceID
    withAnimation(.easeOut(duration: AnimationValues.Sidebar.clearTiltDuration), completionCriteria: .logicallyComplete) {
      isClearHovered = false
      dumpAngle = AnimationValues.Sidebar.clearTiltAngle
    } completion: {
      withAnimation(.easeInOut(duration: AnimationValues.Sidebar.clearReturnDuration), completionCriteria: .logicallyComplete) {
        dumpAngle = 0
      } completion: {
        withAnimation(.smooth(duration: AnimationValues.Sidebar.reorderDuration)) {
          workspace.clearTemporaryTabs(in: spaceID)
        }
        clearingSpaceID = nil
      }
    }
  }

  private func pinnedGrid(columns: Int) -> some View {
    let rows = SpaceTabPanelRow.makeTabs(workspace.globalPinnedTabs.map(\.id),
      spaceID: workspace.selectedSpaceID, tier: .global,
      groups: workspace.spaces.flatMap(\.splitGroups), liftedID: tabDrag.sidebarLiftedTabID,
      liftedIDs: tabDrag.sidebarLiftedTabIDs,
      drop: (tabDrag.isDragging ? tabDrag.target : nil).map { .init(tier: $0.tier, before: $0.before) },
      paneCollapse: tabDrag.paneCollapse)
    return VStack(alignment: .leading, spacing: 3) {
      if rows.isEmpty {
        Image(systemName: "pin")
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity)
          .frame(height: topPinHeight)
          .background(Color.primary.opacity(0.04), in: SidebarTabAppearance.glassShape)
          .help("Pin tabs for all Spaces")
      } else {
        SpaceTabPanel(rows: rows, drag: tabDrag, columns: columns, rowHeight: topPinHeight,
          rowSpacing: BrowserLayout.sidebarTopPinSpacing) { row in
          if let group = row.splitGroup {
            groupDecoration(group, members: row.tabIDs, tier: .global)
          } else if row.id == .gap(workspace.selectedSpaceID) {
            SidebarTabDropSlot()
          } else {
            Color.clear.allowsHitTesting(false)
          }
        } tabContent: { row, id in
          panelTab(row, id: id)
        } rowBackground: { row in
          groupSurface(row)
        }
      }
    }
    .help("Workspace pins stay visible when you switch Spaces")
  }

  private var spacePinMembership: [UUID: Set<UUID>] {
    Dictionary(uniqueKeysWithValues: workspace.spaces.map { ($0.id, Set($0.pinnedTabIDs)) })
  }

  private func visiblePinnedTabs(in space: BrowserSpace) -> [BrowserTab] {
    let hiddenIDs = hiddenSpacePinIDs[space.id] ?? []
    return space.pinnedTabIDs.filter { !hiddenIDs.contains($0) }.compactMap(workspace.tab(withID:))
  }

  @ViewBuilder
  private func panelTab(_ row: SpaceTabPanelRow, id: UUID) -> some View {
    if let tab = workspace.tab(withID: id), let tier = row.tier {
      tabElement(tab, tier: tier, group: row.splitGroup, compact: row.tabIDs.count > 1)
        .onHover { hovering in
          if hovering { hoveredTabIDs.insert(id) } else { hoveredTabIDs.remove(id) }
        }
    }
  }

  private func groupDecoration(_ group: BrowserSplitLayout, members: [UUID],
                               tier: WorkspaceCollection.TabTier?) -> some View {
    SidebarSplitTabDecoration(group: group, members: members,
      isHovered: members.contains { hoveredTabIDs.contains($0) } && tabDrag.tabID == nil,
      usesScrollEdge: tier != .global) {
        workspace.ungroupSplit(containing: group.leftTabID)
      }
  }

  @ViewBuilder
  private func groupSurface(_ row: SpaceTabPanelRow) -> some View {
    if let group = row.splitGroup {
      let selected = group.contains(workspace.selectedTabID) && !workspace.isSpotlightPresented
      let isTopPin = row.tier == .global
      Color.clear
        .modifier(SidebarTabSurface(isStable: selected,
          isHovered: row.tabIDs.contains { hoveredTabIDs.contains($0) } && tabDrag.tabID == nil,
          idleFill: isTopPin ? 0.04 : 0, usesScrollEdge: !isTopPin))
        .scaleEffect(isTopPin && selected ? AnimationValues.Sidebar.selectedTopPinScale : 1)
    }
  }

  private func tabElement(_ tab: BrowserTab, tier: WorkspaceCollection.TabTier,
                          group: BrowserSplitLayout?, compact: Bool) -> some View {
    let anchor = group?.focusedTabID ?? group?.leftTabID ?? tab.id
    return SidebarTabRow(tab: tab, session: workspace.browserSession(for: tab.id),
      selected: workspace.selectedTabID == tab.id && !workspace.isSpotlightPresented,
      tier: tier, group: group, isCompact: compact,
      isTabDragActive: tabDrag.tabID != nil,
      onSelect: { select(tab.id) }, onClose: { workspace.closeTab(id: tab.id) },
      onPinGlobally: {
        withAnimation(tabDrag.panelLayoutAnimation) {
          if group != nil { workspace.moveSplitGroup(containing: anchor, to: .global) }
          else { _ = workspace.moveTab(tab.id, to: .global) }
        }
      }, onPinInSpace: {
        if tier == .global {
          withAnimation(tabDrag.panelLayoutAnimation) {
            if group != nil { workspace.moveSplitGroup(containing: anchor, to: .space(workspace.selectedSpaceID)) }
            else { _ = workspace.moveTab(tab.id, to: .space(workspace.selectedSpaceID)) }
          }
        } else { toggleSpacePin(anchor) }
      }, onMakeTemporary: {
        if tier == .global {
          withAnimation(tabDrag.panelLayoutAnimation) {
            if group != nil { workspace.moveSplitGroup(containing: anchor, to: .temporary(workspace.selectedSpaceID)) }
            else { _ = workspace.moveTab(tab.id, to: .temporary(workspace.selectedSpaceID)) }
          }
        } else { toggleSpacePin(anchor) }
      }, onUngroup: { workspace.ungroupSplit(containing: anchor) },
      onSwap: { workspace.swapSplitSides(containing: anchor) })
  }

  private func select(_ id: UUID) {
    let containerID = workspace.splitGroup(containing: id)?.leftTabID ?? id
    guard !tabDrag.suppressesClick(on: containerID) else { return }
    // AppKit ends the address field's editing before this button action runs.
    // An explicit sidebar selection supplies the page-focus intent rather than
    // trying to infer it after the old native editor has already resigned.
    workspace.selectTab(id: id, focusingPage: true)
  }

  private func move(_ id: UUID, to target: SidebarTabDropTarget) -> Bool {
    var moved = false
    withAnimation(.smooth(duration: AnimationValues.Sidebar.reorderDuration)) {
      if workspace.splitGroup(containing: id) != nil {
        moved = workspace.moveSplitGroup(containing: id, to: target.tier, before: target.before)
      } else {
        moved = workspace.moveTab(id, to: target.tier, before: target.before)
      }
    }
    return moved
  }

  private func toggleSpacePin(_ id: UUID) {
    guard let destination = workspace.spacePinToggleTarget(for: id) else { return }
    let target = SidebarTabDropTarget(tier: destination.tier, before: destination.before)
    let source: WorkspaceCollection.TabTier = destination.tier == .space(workspace.selectedSpaceID)
      ? .temporary(workspace.selectedSpaceID) : .space(workspace.selectedSpaceID)
    let rowID = workspace.splitGroup(containing: id)?.leftTabID ?? id
    if let splitView = chromeLayout.splitView, let sidebar = splitView.subviews.first,
       splitView.isSubviewCollapsed(sidebar) {
      _ = move(rowID, to: target)
    } else {
      tabDrag.animateMove(rowID, from: source, to: target, move: move)
    }
  }

  private func tabDragGesture(width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named(SidebarTabDragSpace.name))
      .updating($isTabDragGestureActive) { _, isActive, _ in isActive = true }
      .onChanged { value in
        tabDrag.pointerMoved(from: value.startLocation, to: value.location,
                             layout: tabDragLayout(width: width))
      }
      .onEnded { _ in
        tabDrag.drop(move)
      }
  }

  private func tabDragLayout(width: CGFloat) -> SidebarTabDragLayout {
    let space = workspace.spaces.first { $0.id == workspace.selectedSpaceID }
    let globalIDs = workspace.globalPinnedTabs.map(\.id)
    let globalRightIDs = Set(globalIDs.flatMap { workspace.splitGroup(containing: $0)?.tabIDs.dropFirst() ?? [] })
    let groupedRightIDs = Set(space?.splitGroups.flatMap { $0.tabIDs.dropFirst() } ?? [])
    let pinIDs = (space.map { visiblePinnedTabs(in: $0).map(\.id) } ?? [])
      .filter { !groupedRightIDs.contains($0) }
    let columns = CGFloat(columns(for: width))
    return SidebarTabDragLayout(
      spaceID: workspace.selectedSpaceID,
      globalTabIDs: globalIDs.filter { !globalRightIDs.contains($0) },
      globalPinnedTabCount: globalIDs.count,
      groupedTabIDs: Set(workspace.spaces.flatMap { $0.splitGroups.flatMap(\.tabIDs) }),
      groupSizes: Dictionary(uniqueKeysWithValues: workspace.spaces.flatMap {
        $0.splitGroups.map { ($0.leftTabID, $0.tabIDs.count) }
      }),
      spacePinTabIDs: pinIDs,
      temporaryTabIDs: (space?.tabIDs ?? []).filter {
        !(space?.pinnedTabIDs.contains($0) ?? false) && !globalIDs.contains($0) && !groupedRightIDs.contains($0)
      },
      tileSize: CGSize(width: (width - 2 * topPinEdgeInset - BrowserLayout.sidebarTopPinSpacing * (columns - 1)) / columns,
                       height: topPinHeight),
      topInset: chromeLayout.topInset)
  }

  private var footer: some View {
    VStack(spacing: 7) {
      HStack(spacing: 0) {
        let spaces = workspace.spaces
        let selectedIndex = spaces.firstIndex(where: { $0.id == workspace.selectedSpaceID }) ?? 0
        let start = min(max(0, selectedIndex - 1), max(0, spaces.count - 4))
        ForEach(Array(spaces.dropFirst(start).prefix(4))) { space in
          Button {
            withAnimation(.smooth(duration: AnimationValues.Sidebar.reorderDuration)) { workspace.selectSpace(id: space.id) }
          } label: {
            Group {
              if space.id == workspace.selectedSpaceID {
                SpaceIconView(icon: space.icon, size: SidebarTabAppearance.faviconSize)
              } else {
                Circle()
                  .fill(Color.primary.opacity(0.25))
                  .frame(width: 7, height: 7)
              }
            }
              .frame(maxWidth: .infinity)
              .frame(height: 27)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(space.name)
          .accessibilityLabel("Space: \(space.name)")
          .accessibilityAddTraits(space.id == workspace.selectedSpaceID ? [.isSelected] : [])
          .contextMenu {
            Button("Rename Space") { promptRename(space) }
          }
        }
        Button {
          withAnimation(.smooth(duration: AnimationValues.Sidebar.reorderDuration)) { _ = workspace.createSpace() }
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 16, weight: .medium))
            .frame(width: 32, height: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Space")
        .accessibilityLabel("New Space")
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 9)
    .padding(.bottom, 11)
  }

  private func promptRename(_ space: BrowserSpace) {
    let alert = NSAlert()
    alert.messageText = "Rename Space"
    let field = NSTextField(string: space.name)
    field.frame.size = NSSize(width: 240, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    _ = workspace.renameSpace(id: space.id, name: field.stringValue)
  }
}

enum SpacePaging {
  static func destinationIndex(current: Int, count: Int, displacement: CGFloat, width: CGFloat) -> Int {
    guard count > 0, width > 0 else { return current }
    let threshold = min(width * 0.22, 72)
    if displacement <= -threshold { return min(current + 1, count - 1) }
    if displacement >= threshold { return max(current - 1, 0) }
    return current
  }
}

/// A small outlined trash can with a lid that can move independently of its body.
private struct ClearTrashIcon: View {
  let isLidOpen: Bool
  let dumpAngle: Double

  var body: some View {
    ZStack {
      Path { path in
        path.move(to: CGPoint(x: 2.1, y: 4.7))
        path.addLine(to: CGPoint(x: 3, y: 12))
        path.addQuadCurve(to: CGPoint(x: 4, y: 13), control: CGPoint(x: 3.1, y: 13))
        path.addLine(to: CGPoint(x: 10, y: 13))
        path.addQuadCurve(to: CGPoint(x: 11, y: 12), control: CGPoint(x: 10.9, y: 13))
        path.addLine(to: CGPoint(x: 11.9, y: 4.7))
        path.move(to: CGPoint(x: 5.2, y: 6.5))
        path.addLine(to: CGPoint(x: 5.5, y: 10.8))
        path.move(to: CGPoint(x: 8.8, y: 6.5))
        path.addLine(to: CGPoint(x: 8.5, y: 10.8))
      }
      .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))

      Path { path in
        path.move(to: CGPoint(x: 1, y: 3.5))
        path.addLine(to: CGPoint(x: 13, y: 3.5))
        path.move(to: CGPoint(x: 5, y: 3.5))
        path.addLine(to: CGPoint(x: 5.5, y: 1.5))
        path.addLine(to: CGPoint(x: 8.5, y: 1.5))
        path.addLine(to: CGPoint(x: 9, y: 3.5))
      }
      .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
      .rotationEffect(.degrees(isLidOpen ? AnimationValues.Sidebar.clearLidAngle : 0),
                      anchor: UnitPoint(x: 1 / 14, y: 3.5 / 14))
    }
    .frame(width: 14, height: 14)
    .rotationEffect(.degrees(dumpAngle), anchor: .bottom)
    .accessibilityHidden(true)
  }
}

private struct SidebarResizeHandle: NSViewRepresentable {
  let layout: SidebarChromeLayout

  func makeNSView(context: Context) -> ResizeView {
    let view = ResizeView()
    view.layout = layout
    return view
  }

  func updateNSView(_ view: ResizeView, context: Context) {
    view.layout = layout
  }

  final class ResizeView: NSView {
    var layout: SidebarChromeLayout?

    override func resetCursorRects() {
      addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
      // Keep the drag sequence attached to this view.
      print("PROBE resize mouseDown"); fflush(stdout) // PROBE-LINE
    }

    override func mouseDragged(with event: NSEvent) {
      print("PROBE resize mouseDragged \(event.locationInWindow.x)"); fflush(stdout) // PROBE-LINE
      layout?.resizeSidebar(toWindowX: event.locationInWindow.x)
    }

  }
}

extension BrowserTab {
  /// Top pin shows a site's initial when it has no favicon.
  var pinFallbackLetter: String {
    String((url?.host ?? displayTitle)
      .replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased()
  }
}

/// The group adds only native separators and its ungroup control. Tabs are
/// retained siblings in SpaceTabPanel, with no nested surface/background.
private struct SidebarSplitTabDecoration: View {
  let group: BrowserSplitLayout
  let members: [UUID]
  let isHovered: Bool
  let usesScrollEdge: Bool
  let onUngroup: () -> Void
  @State private var isButtonHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var showsButton: Bool { isHovered || isButtonHovered }

  var body: some View {
    HStack(spacing: 0) {
      ForEach(members, id: \.self) { id in
        Color.clear.frame(maxWidth: .infinity)
        if id != members.last {
          Divider()
            .frame(height: BrowserLayout.sidebarSplitSeparatorHeight)
            .frame(width: BrowserLayout.sidebarSplitMemberSpacing)
        }
      }
    }
    .allowsHitTesting(false)
    .modifier(SidebarScrollEdge(isEnabled: usesScrollEdge))
    .overlay(alignment: .topLeading) {
      Button(action: onUngroup) {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.gray)
          .frame(width: 21, height: 21)
          .background(.white, in: Circle())
          .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .offset(x: -5, y: -6)
      .opacity(showsButton ? 1 : 0)
      .allowsHitTesting(showsButton)
      .accessibilityHidden(!showsButton)
      .onHover { isButtonHovered = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: AnimationValues.Sidebar.hoverDuration), value: showsButton)
      .help("Ungroup Tabs — keep the left tab active")
      .accessibilityLabel("Ungroup Tabs")
    }
    .accessibilityIdentifier("split-group-\(group.id.uuidString)")
  }
}

private struct SpaceIconView: View {
  let icon: BrowserSpaceIcon
  let size: CGFloat

  var body: some View {
    Group {
      switch icon {
      case .emoji(let emoji): Text(emoji)
      case .systemImage(let name): Image(systemName: name)
      }
    }
    .font(.system(size: size))
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

private struct SidebarSpaceRow: View {
  let space: BrowserSpace
  let isCollapsed: Bool
  let isTabDragActive: Bool
  let onToggle: () -> Void
  let onRename: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 0) {
        SidebarRowLabel(title: space.name) {
          SpaceIconView(icon: space.icon, size: SidebarTabAppearance.faviconSize)
        }
        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 29, height: 32)
          .opacity(isCollapsed || isHovered ? 1 : 0)
          .accessibilityHidden(true)
      }
      .padding(.trailing, 3)
      .frame(height: BrowserLayout.sidebarTabRowHeight)
      .contentShape(SidebarTabAppearance.glassShape)
    }
    .buttonStyle(.plain)
    .background {
      if isHovered && !isTabDragActive {
        SidebarTabAppearance.glassShape.fill(.primary.opacity(0.06))
      }
    }
    .onHover { isHovered = $0 }
    .contextMenu { Button("Rename Space", action: onRename) }
    .help(isCollapsed ? "Expand Space Pins" : "Collapse Space Pins")
    .accessibilityLabel("Space: \(space.name)")
    .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
    .accessibilityIdentifier("space-row-\(space.id.uuidString)")
  }
}

/// A tab owns the same native select/close buttons in every row configuration.
private struct SidebarTabRow: View {
  let tab: BrowserTab
  let session: (any BrowserSessionProtocol)?
  let selected: Bool
  let tier: WorkspaceCollection.TabTier
  let group: BrowserSplitLayout?
  let isCompact: Bool
  let isTabDragActive: Bool
  let onSelect: () -> Void
  let onClose: () -> Void
  let onPinGlobally: () -> Void
  let onPinInSpace: () -> Void
  let onMakeTemporary: () -> Void
  let onUngroup: () -> Void
  let onSwap: () -> Void
  @StateObject private var interaction = BrowserInteractionState()
  @State private var isCloseHovered = false
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var isTopPin: Bool { tier == .global }
  private var showsCloseButton: Bool {
    !isTopPin && !isTabDragActive && interaction.isHovered
  }
  private var closeButtonWidth: CGFloat {
    isTopPin ? 0 : BrowserLayout.sidebarTabCloseButtonWidth
  }
  private var highlightsCloseButton: Bool { showsCloseButton && isCloseHovered }

  var body: some View {
    ZStack(alignment: .trailing) {
      Button(action: onSelect) {
        SidebarRetainedTabLabel(pageURL: tab.url, session: session, title: tab.displayTitle,
          fallbackLetter: isTopPin ? tab.pinFallbackLetter : nil,
          compactAmount: isCompact ? 1 : 0, topPinAmount: isTopPin ? 1 : 0)
          // Only reserve title space while the retained close control is visible.
          .padding(.trailing, showsCloseButton ? closeButtonWidth : 0)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(tab.displayTitle)
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(highlightsCloseButton
            ? (colorScheme == .dark ? Color.white : Color.black) : Color.secondary)
          .scaleEffect(highlightsCloseButton ? AnimationValues.Sidebar.closeButtonHoverScale : 1)
          .animation(reduceMotion ? nil : .easeInOut(duration: AnimationValues.Sidebar.closeButtonHoverDuration),
            value: highlightsCloseButton)
          .frame(width: closeButtonWidth)
          .frame(maxHeight: .infinity)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .opacity(showsCloseButton ? 1 : 0)
      .allowsHitTesting(showsCloseButton)
      .accessibilityHidden(!showsCloseButton)
      .onHover { isCloseHovered = $0 }
      .help("Close Tab")
      .accessibilityLabel("Close \(tab.displayTitle)")
    }
    .padding(.trailing, isTopPin ? 0 : BrowserLayout.sidebarTabTrailingInset)
    .modifier(SidebarScrollEdge(isEnabled: !isTopPin))
    .modifier(SidebarTabSurface(isStable: selected && group == nil,
      isHovered: group == nil && interaction.isHovered && !isTabDragActive,
      idleFill: group == nil && isTopPin ? 0.04 : 0, usesScrollEdge: !isTopPin,
      stableBorderOpacity: isTopPin ? 0.5 : 0.35,
      hoverBorderOpacity: isTopPin ? 0.25 : 0))
    .scaleEffect(isTopPin && selected && group == nil ? AnimationValues.Sidebar.selectedTopPinScale : 1)
    .onHover { interaction.isHovered = $0 }
    .onChange(of: showsCloseButton) { _, shows in
      if !shows { isCloseHovered = false }
    }
    .contextMenu {
      if group != nil {
        Button("Ungroup Tabs", action: onUngroup)
        Button("Swap Sides", action: onSwap)
        Button("Pin Group for All Spaces", action: onPinGlobally)
        if isTopPin {
          Button("Pin Group in This Space", action: onPinInSpace)
          Button("Make Group Temporary", action: onMakeTemporary)
        } else if case .space = tier {
          Button("Make Group Temporary", action: onMakeTemporary)
            .keyboardShortcut("d", modifiers: .command)
        } else {
          Button("Pin Group in This Space", action: onPinInSpace)
            .keyboardShortcut("d", modifiers: .command)
        }
      } else {
        if !isTopPin { Button("Pin for All Spaces", action: onPinGlobally) }
        if case .space = tier {
          Button("Make Temporary", action: onMakeTemporary)
            .keyboardShortcut("d", modifiers: .command)
        } else {
          Button("Pin in This Space", action: onPinInSpace)
            .keyboardShortcut("d", modifiers: .command)
        }
      }
      Button("Close Tab", action: onClose)
    }
    .help(tab.displayTitle)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}

/// Locks each precision-scroll gesture to one axis. Horizontal events are
/// consumed so their vertical component cannot move the tab list.
private struct SpaceSwipeMonitor: NSViewRepresentable {
  let onScroll: (CGFloat) -> Void
  let onEnd: () -> Void

  func makeNSView(context: Context) -> MonitorView {
    let view = MonitorView()
    view.onScroll = onScroll
    view.onEnd = onEnd
    return view
  }

  func updateNSView(_ view: MonitorView, context: Context) {
    view.onScroll = onScroll
    view.onEnd = onEnd
  }

  final class MonitorView: NSView {
    private enum Axis { case horizontal, vertical }

    var onScroll: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    nonisolated(unsafe) private var monitor: Any?
    private var lockedAxis: Axis?
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var lastEventTime: TimeInterval = 0

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        guard let self else { return event }
        return self.handle(event)
      }
    }

    deinit {
      if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func finishGesture() {
      if lockedAxis == .horizontal { onEnd?() }
      lockedAxis = nil
      accumulatedX = 0
      accumulatedY = 0
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
      guard let window, event.window === window, event.hasPreciseScrollingDeltas else { return event }
      guard event.momentumPhase == [] else { return event }
      if event.phase == .ended || event.phase == .cancelled {
        let wasHorizontal = lockedAxis == .horizontal
        finishGesture()
        return wasHorizontal ? nil : event
      }
      let point = convert(event.locationInWindow, from: nil)
      guard bounds.contains(point) else { return event }
      if event.phase == .began || (event.phase == [] && event.timestamp - lastEventTime > 0.5) {
        finishGesture()
      }
      lastEventTime = event.timestamp

      switch lockedAxis {
      case .horizontal:
        onScroll?(event.scrollingDeltaX)
        return nil
      case .vertical:
        return event
      case nil:
        accumulatedX += event.scrollingDeltaX
        accumulatedY += event.scrollingDeltaY
        let x = abs(accumulatedX)
        let y = abs(accumulatedY)
        guard max(x, y) >= 4 else { return nil }
        if x >= y * 1.25 || (max(x, y) >= 12 && x >= y) {
          lockedAxis = .horizontal
          onScroll?(accumulatedX)
          return nil
        }
        if y >= x * 1.25 || max(x, y) >= 12 {
          lockedAxis = .vertical
          return event
        }
        return nil
      }
    }
  }
}
