//
//  TabSidebarView.swift
//  NativeBrowser
//
//  Sidebar blocks: fixed top pin (.global), fixed Space header and scrolling tabs.
//  Space tab contains space pin (.space) and temporary (.temporary) tabs.
//

import AppKit
import SwiftUI

enum SidebarTabAppearance {
  static let faviconSize: CGFloat = 18
  static let glassShape = RoundedRectangle(cornerRadius: BrowserLayout.contentCornerRadius, style: .continuous)
}

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

  func scroll(_ delta: CGFloat, selectedIndex: Int, count: Int, width: CGFloat) {
    let atFirst = selectedIndex == 0 && delta > 0
    let atLast = selectedIndex == count - 1 && delta < 0
    let resistance: CGFloat = atFirst || atLast ? 0.22 : 1
    displacement = max(-width, min(width, displacement + delta * resistance))
    offset = displacement
  }

  func reset() {
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
        try? await Task.sleep(for: .milliseconds(400))
        if outgoingIndex == oldIndex { outgoingIndex = nil }
      }
    }
  }
}

struct TabSidebarView: View {
  @ObservedObject var workspace: BrowserWorkspaceStore
  @EnvironmentObject private var chromeLayout: SidebarChromeLayout
  @State private var pageSwipeState = SpacePageSwipeState()
  @State private var tabDrag = SidebarTabDrag()
  @State private var isSidebarHovered = false
  @State private var isClearHovered = false
  @State private var hoveredNewTabSpaceID: UUID?
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
        pinnedGrid(columns: columns(for: geometry.size.width), width: geometry.size.width)
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
        withAnimation(.smooth(duration: 0.34)) {
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
      .onAppear { chromeLayout.attachTabDrag(tabDrag) }
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
          withAnimation(.easeOut(duration: 0.18)) { isClearHovered = false }
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
    let pinSlots = slots(pinnedTabs, tier: .space(space.id))
    let spotlightIsActive = workspace.isSpotlightPresented && space.id == workspace.selectedSpaceID
    let newTabIsHovered = hoveredNewTabSpaceID == space.id && tabDrag.tabID == nil

    return ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        tierRows(pinSlots, tier: .space(space.id))

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
              withAnimation(.easeOut(duration: 0.18)) { isClearHovered = isHovered }
            }
          }
        }
        .frame(height: BrowserLayout.sidebarSectionDividerHeight)
        .padding(.horizontal, 9)
        .modifier(SidebarScrollEdge())

        Button {
          workspace.selectSpace(id: space.id)
          workspace.presentSpotlight()
        } label: {
          Label("New Tab", systemImage: "plus")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(SidebarTabAppearance.glassShape)
            .modifier(SidebarScrollEdge())
        }
        .buttonStyle(.plain)
        .foregroundStyle(spotlightIsActive ? Color.primary : Color.secondary)
        .background {
          if spotlightIsActive {
            Color.clear.browserChromeGlassSurface(in: SidebarTabAppearance.glassShape)
              .modifier(SidebarScrollEdgeSurface())
          } else if newTabIsHovered {
            SidebarTabAppearance.glassShape.fill(.primary.opacity(0.06))
              .modifier(SidebarScrollEdge())
          }
        }
        .overlay {
          if spotlightIsActive {
            SidebarTabAppearance.glassShape.strokeBorder(.white.opacity(0.35), lineWidth: 1)
              .modifier(SidebarScrollEdge())
          }
        }
        .onHover { isHovered in
          if isHovered {
            hoveredNewTabSpaceID = space.id
          } else if hoveredNewTabSpaceID == space.id {
            hoveredNewTabSpaceID = nil
          }
        }
        .help("Open Spotlight to create a tab")
        .accessibilityAddTraits(spotlightIsActive ? [.isSelected] : [])

        tierRows(slots(temporaryTabs, tier: .temporary(space.id)), tier: .temporary(space.id))
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
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
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

  private func animateClear(in spaceID: UUID) {
    guard clearingSpaceID == nil else { return }
    clearingSpaceID = spaceID
    withAnimation(.easeOut(duration: 0.14), completionCriteria: .logicallyComplete) {
      isClearHovered = false
      dumpAngle = 18
    } completion: {
      withAnimation(.easeInOut(duration: 0.16), completionCriteria: .logicallyComplete) {
        dumpAngle = 0
      } completion: {
        withAnimation(.smooth(duration: 0.28)) {
          workspace.clearTemporaryTabs(in: spaceID)
        }
        clearingSpaceID = nil
      }
    }
  }

  private func pinnedGrid(columns: Int, width: CGFloat) -> some View {
    let tileSlots = slots(workspace.globalPinnedTabs, tier: .global)
    return VStack(alignment: .leading, spacing: 3) {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BrowserLayout.sidebarTopPinSpacing), count: columns),
                spacing: BrowserLayout.sidebarTopPinSpacing) {
        ForEach(tileSlots) { slot in
          switch slot {
          case .tab(let tab):
            PinnedTile(tab: tab, session: workspace.session(for: tab.id),
                       selected: workspace.selectedTabID == tab.id && !workspace.isSpotlightPresented,
                       height: topPinHeight,
                       isTabDragActive: tabDrag.tabID != nil) {
              select(tab.id)
            } onClose: {
              workspace.closeTab(id: tab.id)
            } onPinInSpace: {
              withAnimation(.smooth(duration: 0.28)) { _ = workspace.moveTab(tab.id, to: .space(workspace.selectedSpaceID)) }
            } onMakeTemporary: {
              withAnimation(.smooth(duration: 0.28)) { _ = workspace.moveTab(tab.id, to: .temporary(workspace.selectedSpaceID)) }
            }
            .modifier(SidebarTabDragItem(drag: tabDrag, tabID: tab.id, tier: .global))
          case .group(let group):
            splitRow(group, tier: .global)
          case .gap:
            Color.clear.frame(height: topPinHeight)
          }
        }
        if tileSlots.isEmpty {
          Image(systemName: "pin")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .frame(height: topPinHeight)
            .background(Color.primary.opacity(0.04), in: SidebarTabAppearance.glassShape)
            .help("Pin tabs for all Spaces")
          }
      }
      .animation(.smooth(duration: 0.28), value: tileSlots.map(\.id))

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

  /// While a tab is lifted it leaves its tier, and the tier it would land in
  /// opens a gap at that place.
  private func slots(_ tabs: [BrowserTab], tier: WorkspaceCollection.TabTier) -> [SidebarSlot] {
    let available = tabs.filter {
      guard let lifted = tabDrag.liftedTabID else { return true }
      return $0.id != lifted && workspace.splitGroup(containing: $0.id)?.leftTabID != lifted
    }
    let ids = Set(available.map(\.id))
    var emitted = Set<UUID>()
    var result: [SidebarSlot] = []
    for tab in available {
      guard !emitted.contains(tab.id) else { continue }
      if let group = workspace.splitGroup(containing: tab.id), group.tabIDs.allSatisfy({ ids.contains($0) }) {
        result.append(.group(group))
        emitted.formUnion(group.tabIDs)
      } else {
        result.append(.tab(tab))
        emitted.insert(tab.id)
      }
    }
    if tabDrag.liftedTabID != nil, let target = tabDrag.target, target.tier == tier {
      let index = target.before.flatMap { before in result.firstIndex { $0.contains(before) } }
      result.insert(.gap, at: index ?? result.count)
    }
    return result
  }

  private func tierRows(_ slots: [SidebarSlot], tier: WorkspaceCollection.TabTier) -> some View {
    LazyVStack(spacing: 5) {
      ForEach(slots) { slot in
        switch slot {
        case .tab(let tab):
          row(tab, tier: tier)
        case .group(let group):
          splitRow(group, tier: tier)
        case .gap:
          Color.clear.frame(height: BrowserLayout.sidebarTabRowHeight)
        }
      }
      if case .space = tier {
        if slots.isEmpty {
          // Keep an empty pin tier reachable as a drop target.
          Color.clear.frame(height: BrowserLayout.sidebarEmptyPinDropHeight)
        }
      } else {
        Color.clear.frame(height: slots.isEmpty ? 16 : 8)
      }
    }
    .onSidebarFrameChange { tabDrag.register(tier, frame: $0) }
    .animation(.smooth(duration: 0.28), value: slots.map(\.id))
  }

  @ViewBuilder
  private func splitRow(_ group: BrowserSplitLayout, tier: WorkspaceCollection.TabTier) -> some View {
    if let left = workspace.tab(withID: group.leftTabID), let right = workspace.tab(withID: group.rightTabID) {
      let focusedID = group.focusedTabID ?? group.leftTabID
      let owner = workspace.spaceID(forTabID: group.leftTabID) ?? workspace.selectedSpaceID
      let height: CGFloat? = switch tier {
      case .global: topPinHeight
      case .space: BrowserLayout.sidebarTabRowHeight
      case .temporary: nil
      }
      SidebarSplitTabRow(group: group, left: left, right: right,
        leftSession: workspace.session(for: left.id), rightSession: workspace.session(for: right.id),
        selectedTabID: workspace.isSpotlightPresented ? nil : workspace.selectedTabID,
        drag: tabDrag, tier: tier, height: height, onSelect: select, onClose: { workspace.closeTab(id: $0) },
        onUngroup: { workspace.ungroupSplit(containing: group.leftTabID) },
        onSwap: { workspace.swapSplitSides(containing: focusedID) },
        onPinGlobally: { workspace.moveSplitGroup(containing: focusedID, to: .global) },
        onPin: { workspace.moveSplitGroup(containing: focusedID, to: .space(tier == .global ? workspace.selectedSpaceID : owner)) },
        onMakeTemporary: { workspace.moveSplitGroup(containing: focusedID, to: .temporary(tier == .global ? workspace.selectedSpaceID : owner)) })
    }
  }

  private func row(_ tab: BrowserTab, tier: WorkspaceCollection.TabTier) -> some View {
    SidebarTabRow(tab: tab, session: workspace.session(for: tab.id),
                  selected: workspace.selectedTabID == tab.id && !workspace.isSpotlightPresented,
                  tier: tier,
                  isTabDragActive: tabDrag.tabID != nil) {
      select(tab.id)
    } onClose: {
      workspace.closeTab(id: tab.id)
    } onPinGlobally: {
      withAnimation(.smooth(duration: 0.28)) { _ = workspace.moveTab(tab.id, to: .global) }
    } onPinInSpace: {
      let spaceID: UUID
      switch tier {
      case .space(let id), .temporary(let id): spaceID = id
      case .global: spaceID = workspace.selectedSpaceID
      }
      withAnimation(.smooth(duration: 0.28)) { _ = workspace.moveTab(tab.id, to: .space(spaceID)) }
    } onMakeTemporary: {
      let spaceID: UUID
      switch tier {
      case .space(let id), .temporary(let id): spaceID = id
      case .global: spaceID = workspace.selectedSpaceID
      }
      withAnimation(.smooth(duration: 0.28)) { _ = workspace.moveTab(tab.id, to: .temporary(spaceID)) }
    }
    .id(tab.id)
    .modifier(SidebarTabDragItem(drag: tabDrag, tabID: tab.id, tier: tier))
  }

  private func select(_ id: UUID) {
    guard !tabDrag.suppressesClick(on: id) else { return }
    // AppKit ends the address field's editing before this button action runs.
    // An explicit sidebar selection supplies the page-focus intent rather than
    // trying to infer it after the old native editor has already resigned.
    workspace.selectTab(id: id, focusingPage: true)
  }

  private func move(_ id: UUID, to target: SidebarTabDropTarget) -> Bool {
    var moved = false
    withAnimation(.smooth(duration: 0.28)) {
      if workspace.splitGroup(containing: id) != nil {
        moved = workspace.moveSplitGroup(containing: id, to: target.tier, before: target.before)
      } else {
        moved = workspace.moveTab(id, to: target.tier, before: target.before)
      }
    }
    return moved
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
    let globalRightIDs = Set(globalIDs.compactMap { workspace.splitGroup(containing: $0)?.rightTabID })
    let groupedRightIDs = Set(space?.splitGroups.map(\.rightTabID) ?? [])
    let pinIDs = (space.map { visiblePinnedTabs(in: $0).map(\.id) } ?? [])
      .filter { !groupedRightIDs.contains($0) }
    let columns = CGFloat(columns(for: width))
    return SidebarTabDragLayout(
      spaceID: workspace.selectedSpaceID,
      globalTabIDs: globalIDs.filter { !globalRightIDs.contains($0) },
      globalPinnedTabCount: globalIDs.count,
      groupedTabIDs: Set(workspace.spaces.flatMap { $0.splitGroups.flatMap(\.tabIDs) }),
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
            withAnimation(.smooth(duration: 0.28)) { workspace.selectSpace(id: space.id) }
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
          withAnimation(.smooth(duration: 0.28)) { _ = workspace.createSpace() }
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
      .rotationEffect(.degrees(isLidOpen ? -18 : 0), anchor: UnitPoint(x: 1 / 14, y: 3.5 / 14))
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

private struct PinnedTile: View {
  let tab: BrowserTab
  let session: BrowserSession?
  let selected: Bool
  let height: CGFloat
  let isTabDragActive: Bool
  let onSelect: () -> Void
  let onClose: () -> Void
  let onPinInSpace: () -> Void
  let onMakeTemporary: () -> Void
  @StateObject private var interaction = BrowserInteractionState()

  private var showsHover: Bool { interaction.isHovered && !isTabDragActive }

  var body: some View {
    Button(action: onSelect) {
      TabFaviconView(
        pageURL: tab.url,
        session: session,
        size: SidebarTabAppearance.faviconSize,
        fallbackLetter: tab.pinFallbackLetter)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .contentShape(SidebarTabAppearance.glassShape)
    }
    .buttonStyle(.plain)
    .background {
      if selected {
        Color.clear.browserChromeGlassSurface(in: SidebarTabAppearance.glassShape)
      } else {
        SidebarTabAppearance.glassShape.fill(.primary.opacity(showsHover ? 0.06 : 0.04))
      }
    }
    .overlay {
      if selected || showsHover {
        SidebarTabAppearance.glassShape.strokeBorder(
          .white.opacity(selected ? 0.5 : 0.25), lineWidth: 1)
      }
    }
    .scaleEffect(selected ? 1.02 : 1)
    .onHover { interaction.isHovered = $0 }
    .contextMenu {
      Button("Pin in This Space", action: onPinInSpace)
      Button("Make Temporary", action: onMakeTemporary)
      Button("Close Tab", action: onClose)
    }
    .help(tab.displayTitle)
    .accessibilityLabel(tab.displayTitle)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}

/// A tab, or the gap a lifted tab would land in.
private enum SidebarSlot: Identifiable {
  case tab(BrowserTab)
  case group(BrowserSplitLayout)
  case gap

  private static let gapID = UUID()

  var id: UUID {
    switch self {
    case .tab(let tab): return tab.id
    case .group(let group): return group.id
    case .gap: return Self.gapID
    }
  }

  func contains(_ tabID: UUID) -> Bool {
    switch self {
    case .tab(let tab): return tab.id == tabID
    case .group(let group): return group.contains(tabID)
    case .gap: return false
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

/// A single sidebar row containing independently selectable split panes.
private struct SidebarSplitTabRow: View {
  let group: BrowserSplitLayout
  let left: BrowserTab
  let right: BrowserTab
  let leftSession: BrowserSession?
  let rightSession: BrowserSession?
  let selectedTabID: UUID?
  let drag: SidebarTabDrag
  let tier: WorkspaceCollection.TabTier
  let height: CGFloat?
  let onSelect: (UUID) -> Void
  let onClose: (UUID) -> Void
  let onUngroup: () -> Void
  let onSwap: () -> Void
  let onPinGlobally: () -> Void
  let onPin: () -> Void
  let onMakeTemporary: () -> Void
  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var selected: Bool { group.contains(selectedTabID) }
  private var showsHover: Bool { isHovered && drag.tabID == nil }
  private var isPinned: Bool {
    if case .temporary = tier { return false }
    return true
  }
  private var contentInset: CGFloat { isPinned ? 2 : 3 }

  var body: some View {
    HStack(spacing: isPinned ? 3 : 2) {
      member(left, session: leftSession)
      member(right, session: rightSession)
    }
    .frame(height: height.map { $0 - 2 * contentInset })
    .padding(contentInset)
    .frame(maxWidth: .infinity)
    .containerShape(SidebarTabAppearance.glassShape)
    .modifier(SidebarScrollEdge(isEnabled: tier != .global))
    .background {
      if selected {
        Color.clear.browserChromeGlassSurface(in: SidebarTabAppearance.glassShape)
          .modifier(SidebarScrollEdgeSurface(isEnabled: tier != .global))
      } else {
        SidebarTabAppearance.glassShape.fill(.primary.opacity(showsHover ? 0.06 : (tier == .global ? 0.04 : 0.035)))
          .modifier(SidebarScrollEdge(isEnabled: tier != .global))
      }
    }
    .overlay {
      if selected {
        SidebarTabAppearance.glassShape.strokeBorder(.white.opacity(0.35), lineWidth: 1)
          .modifier(SidebarScrollEdge(isEnabled: tier != .global))
      }
    }
    .scaleEffect(tier == .global && selected ? 1.02 : 1)
    .contextMenu {
      Button("Ungroup Tabs", action: onUngroup)
      Button("Swap Sides", action: onSwap)
      Button("Pin Group for All Spaces", action: onPinGlobally)
      Button("Pin Group in This Space", action: onPin)
      Button("Make Group Temporary", action: onMakeTemporary)
    }
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
      .opacity(showsHover ? 1 : 0)
      .allowsHitTesting(showsHover)
      .accessibilityHidden(!showsHover)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showsHover)
      .help("Ungroup Tabs — keep the left tab active")
      .accessibilityLabel("Ungroup Tabs")
    }
    .onHover { isHovered = $0 }
    .accessibilityIdentifier("split-group-\(group.id.uuidString)")
    .help("\(left.displayTitle) | \(right.displayTitle)")
    .modifier(SidebarTabDragItem(drag: drag, tabID: group.leftTabID, tier: tier))
  }

  private func member(_ tab: BrowserTab, session: BrowserSession?) -> some View {
    let focused = selected && selectedTabID == tab.id
    let showsClose = showsHover && tier != .global
    return HStack(spacing: 0) {
      Button {
        guard !drag.suppressesClick(on: group.leftTabID) else { return }
        onSelect(tab.id)
      } label: {
        HStack(spacing: 4) {
          TabFaviconView(pageURL: tab.url, session: session, size: tier == .global ? SidebarTabAppearance.faviconSize : 16,
                         fallbackLetter: tier == .global ? tab.pinFallbackLetter : nil)
            .frame(width: 18)
          if tier != .global {
            Text(tab.displayTitle)
              .font(.system(size: 12))
              .lineLimit(1)
            Spacer(minLength: 0)
          }
        }
        .padding(.leading, tier == .global ? 0 : 5)
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: height == nil ? nil : .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(tab.displayTitle)
      .accessibilityAddTraits(focused ? [.isSelected] : [])
      if tier != .global {
        Button { onClose(tab.id) } label: {
          Image(systemName: "xmark")
            .font(.system(size: 8, weight: .semibold))
            .frame(width: 18, height: 30)
        }
        .buttonStyle(.plain)
        .opacity(showsClose ? 0.65 : 0)
        .allowsHitTesting(showsClose)
        .accessibilityLabel("Close \(tab.displayTitle)")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: height == nil ? nil : .infinity)
    .background {
      if isPinned {
        ContainerRelativeShape().fill(.primary.opacity(showsHover ? 0.06 : 0.04))
      } else {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(.primary.opacity(showsHover ? 0.06 : 0.04))
      }
    }
    .help(tab.displayTitle)
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

/// Keeps Space and Tab titles, icons and hit areas on the same grid.
private struct SidebarRowLabel<Icon: View>: View {
  let title: String
  var selected = false
  @ViewBuilder let icon: () -> Icon

  var body: some View {
    HStack(spacing: 9) {
      icon().frame(width: 20)
      Text(title)
        .font(.callout.weight(selected ? .semibold : .regular))
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.leading, 11)
    .frame(maxWidth: .infinity, minHeight: BrowserLayout.sidebarTabRowHeight)
    .contentShape(Rectangle())
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

private struct SidebarTabRow: View {
  let tab: BrowserTab
  let session: BrowserSession?
  let selected: Bool
  let tier: WorkspaceCollection.TabTier
  let isTabDragActive: Bool
  let onSelect: () -> Void
  let onClose: () -> Void
  let onPinGlobally: () -> Void
  let onPinInSpace: () -> Void
  let onMakeTemporary: () -> Void
  @StateObject private var interaction = BrowserInteractionState()

  private var showsHover: Bool { interaction.isHovered && !isTabDragActive }
  private var showsCloseButton: Bool { (interaction.isHovered || selected) && !isTabDragActive }

  var body: some View {
    HStack(spacing: 0) {
      Button(action: onSelect) {
        SidebarRowLabel(title: tab.displayTitle, selected: selected) {
          TabFaviconView(pageURL: tab.url, session: session, size: SidebarTabAppearance.faviconSize)
        }
      }
      .buttonStyle(.plain)
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .frame(width: 29, height: 32)
      }
      .buttonStyle(.plain)
      .opacity(showsCloseButton ? 0.7 : 0)
      .allowsHitTesting(showsCloseButton)
      .help("Close Tab")
    }
    .padding(.trailing, 3)
    .modifier(SidebarScrollEdge())
    .background {
      if selected {
        Color.clear.browserChromeGlassSurface(in: SidebarTabAppearance.glassShape)
          .modifier(SidebarScrollEdgeSurface())
      } else if showsHover {
        SidebarTabAppearance.glassShape.fill(.primary.opacity(0.06))
          .modifier(SidebarScrollEdge())
      }
    }
    .overlay {
      if selected {
        SidebarTabAppearance.glassShape.strokeBorder(.white.opacity(0.35), lineWidth: 1)
          .modifier(SidebarScrollEdge())
      }
    }
    .onHover { interaction.isHovered = $0 }
    .contextMenu {
      Button("Pin for All Spaces", action: onPinGlobally)
      Button("Pin in This Space", action: onPinInSpace)
      if case .space = tier { Button("Make Temporary", action: onMakeTemporary) }
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
