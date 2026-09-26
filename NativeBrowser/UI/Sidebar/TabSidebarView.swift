//
//  TabSidebarView.swift
//  NativeBrowser
//
//  Sidebar terms: top pin = workspace-wide pin (.global), space pin = pin in
//  one Space (.space), temporary = unpinned tab in one Space (.temporary).
//

import AppKit
import SwiftUI

@MainActor
final class SidebarChromeLayout: ObservableObject {
  @Published private(set) var topInset: CGFloat = 0
  weak var splitView: NSSplitView?

  func update(topInset: CGFloat) {
    guard abs(self.topInset - topInset) > 0.5 else { return }
    self.topInset = topInset
  }

  func resizeSidebar(toWindowX x: CGFloat) {
    guard let splitView else { return }
    let splitOriginX = splitView.convert(.zero, to: nil).x
    let width = min(max(x - splitOriginX + 5, BrowserLayout.sidebarMinimumWidth), BrowserLayout.sidebarMaximumWidth)
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
  @EnvironmentObject private var runtime: ApplicationRuntime
  @EnvironmentObject private var chromeLayout: SidebarChromeLayout
  @State private var pageSwipeState = SpacePageSwipeState()
  private let pinGlassOverlap: CGFloat = 24

  private func columns(for width: CGFloat) -> Int {
    width >= 365 ? 4 : (width >= 275 ? 3 : 2)
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        pinnedGrid(columns: columns(for: geometry.size.width), width: geometry.size.width)
          .padding(.horizontal, 12)
          .padding(.top, chromeLayout.topInset + 6)
          .padding(.bottom, 6)
          .background {
            SidebarPinGlassEdge()
              .mask {
                VStack(spacing: 0) {
                  Rectangle()
                  LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                }
              }
              .allowsHitTesting(false)
          }
          .zIndex(1)

        spacePages
          .padding(.top, -pinGlassOverlap)
          .frame(maxHeight: .infinity)

        footer
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.ultraThinMaterial)
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
      .ignoresSafeArea(.container, edges: .top)
    }
  }

  private var selectedSpaceIndex: Int {
    workspace.spaces.firstIndex(where: { $0.id == workspace.selectedSpaceID }) ?? 0
  }

  private var spacePages: some View {
    SpacePageTrack(swipeState: pageSwipeState, selectedIndex: selectedSpaceIndex,
                   pages: workspace.spaces.map { AnyView(spacePage($0)) })
    .accessibilityIdentifier("space-pages")
  }

  private func spacePage(_ space: BrowserSpace) -> some View {
    let pinnedTabs = space.pinnedTabIDs.compactMap(workspace.tab(withID:))
    let globalIDs = Set(workspace.globalPinnedTabs.map(\.id))
    let temporaryTabs = space.tabIDs
      .filter { !space.pinnedTabIDs.contains($0) && !globalIDs.contains($0) }
      .compactMap(workspace.tab(withID:))
    let clearableCount = temporaryTabs.filter { $0.id != workspace.selectedTabID }.count

    return ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        sectionTitle(space.name, symbol: "square.3.layers.3d")
          .modifier(TabInsertionDropModifier { items in move(items, to: .space(space.id)) })
        tierRows(pinnedTabs, tier: .space(space.id))
          .padding(.bottom, pinnedTabs.isEmpty ? 0 : -6)

        if clearableCount > 0 {
          HStack(spacing: 8) {
            Rectangle().fill(.primary.opacity(0.12)).frame(height: 0.5)
            Button {
              withAnimation(.smooth(duration: 0.28)) {
                workspace.clearTemporaryTabs(in: space.id)
              }
            } label: {
              Label("Clear", systemImage: "arrow.down")
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close idle tabs except the active tab")
          }
          .padding(.horizontal, 9)
          .padding(.vertical, 2)
        }

        Button {
          workspace.selectSpace(id: space.id)
          _ = workspace.createTab()
        } label: {
          Label("New Tab", systemImage: "plus")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Create a temporary tab")

        tierRows(temporaryTabs, tier: .temporary(space.id))
      }
      .padding(.horizontal, 10)
      .padding(.top, 8 + pinGlassOverlap)
      .padding(.bottom, 18)
    }
  }

  private func pinnedGrid(columns: Int, width: CGFloat) -> some View {
    let tileSide = (width - 24 - CGFloat(columns - 1) * 9) / CGFloat(columns)
    return VStack(alignment: .leading, spacing: 3) {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: columns), spacing: 9) {
        ForEach(workspace.globalPinnedTabs) { tab in
          PinnedTile(tab: tab, session: workspace.session(for: tab.id),
                     selected: workspace.selectedTabID == tab.id, side: tileSide) {
            workspace.selectTab(id: tab.id)
          } onClose: {
            workspace.closeTab(id: tab.id)
          } onPinInSpace: {
            withAnimation(.smooth(duration: 0.28)) { _ = workspace.moveTab(tab.id, to: .space(workspace.selectedSpaceID)) }
          } onMakeTemporary: {
            withAnimation(.smooth(duration: 0.28)) { _ = workspace.moveTab(tab.id, to: .temporary(workspace.selectedSpaceID)) }
          }
          .draggable(tab.id.uuidString)
          .modifier(TabInsertionDropModifier { items in
            move(items, to: .global, before: tab.id)
          })
        }
        if workspace.globalPinnedTabs.isEmpty {
          Image(systemName: "pin")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .frame(height: tileSide)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
            .modifier(TabInsertionDropModifier { items in move(items, to: .global) })
            .help("Pin tabs for all Spaces")
          }
      }
      .animation(.smooth(duration: 0.28), value: workspace.globalPinnedTabs.map(\.id))

      if !workspace.globalPinnedTabs.isEmpty {
        Color.clear.frame(height: 8)
          .contentShape(Rectangle())
          .modifier(TabInsertionDropModifier { items in move(items, to: .global) })
      }
    }
    .help("Workspace pins stay visible when you switch Spaces")
  }

  private func sectionTitle(_ title: String, symbol: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: symbol).frame(width: 16)
      Text(title).lineLimit(1)
      Spacer(minLength: 0)
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 9)
    .frame(height: 24)
    .contentShape(Rectangle())
  }

  private func tierRows(_ tabs: [BrowserTab], tier: WorkspaceCollection.TabTier) -> some View {
    LazyVStack(spacing: 5) {
      ForEach(tabs) { tab in
        SidebarTabRow(tab: tab, session: workspace.session(for: tab.id),
                      selected: workspace.selectedTabID == tab.id, tier: tier) {
          workspace.selectTab(id: tab.id)
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
        .draggable(tab.id.uuidString)
        .modifier(TabInsertionDropModifier { items in move(items, to: tier, before: tab.id) })
      }
      Color.clear.frame(height: tabs.isEmpty ? 16 : 8)
        .contentShape(Rectangle())
        .modifier(TabInsertionDropModifier { items in move(items, to: tier) })
    }
    .animation(.smooth(duration: 0.28), value: tabs.map(\.id))
  }

  private func move(_ items: [String], to tier: WorkspaceCollection.TabTier, before target: UUID? = nil) -> Bool {
    guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
    var moved = false
    withAnimation(.smooth(duration: 0.28)) {
      moved = workspace.moveTab(id, to: tier, before: target)
    }
    return moved
  }

  private var footer: some View {
    VStack(spacing: 7) {
      HStack(spacing: 4) {
        Button(action: runtime.showHistory) {
          Image(systemName: "clock.arrow.circlepath")
        }.help("History")
        Button(action: runtime.showDownloads) {
          Image(systemName: "arrow.down.circle")
        }.help("Downloads")
        Spacer()
      }
      .buttonStyle(.plain)
      .font(.system(size: 15))
      .padding(.horizontal, 8)

      HStack(spacing: 0) {
        let spaces = workspace.spaces
        let selectedIndex = spaces.firstIndex(where: { $0.id == workspace.selectedSpaceID }) ?? 0
        let start = min(max(0, selectedIndex - 1), max(0, spaces.count - 4))
        ForEach(Array(spaces.dropFirst(start).prefix(4))) { space in
          Button {
            withAnimation(.smooth(duration: 0.28)) { workspace.selectSpace(id: space.id) }
          } label: {
            Circle()
              .fill(space.id == workspace.selectedSpaceID ? Color.accentColor : Color.primary.opacity(0.25))
              .frame(width: space.id == workspace.selectedSpaceID ? 10 : 7,
                     height: space.id == workspace.selectedSpaceID ? 10 : 7)
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
    .background(.regularMaterial)
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

private struct SidebarPinGlassEdge: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .headerView
    view.blendingMode = .withinWindow
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
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

private struct TabInsertionDropModifier: ViewModifier {
  let onDrop: ([String]) -> Bool
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .top) {
        if isTargeted {
          HStack(spacing: 0) {
            Circle()
              .fill(.background)
              .frame(width: 7, height: 7)
              .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 2) }
            Rectangle()
              .fill(Color.accentColor)
              .frame(height: 2)
          }
          .shadow(color: Color.accentColor.opacity(0.25), radius: 3)
          .frame(height: 8)
          .allowsHitTesting(false)
          .transition(.opacity)
        }
      }
      .dropDestination(for: String.self) { items, _ in
        onDrop(items)
      } isTargeted: { targeted in
        withAnimation(.easeOut(duration: 0.12)) { isTargeted = targeted }
      }
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
    }

    override func mouseDragged(with event: NSEvent) {
      layout?.resizeSidebar(toWindowX: event.locationInWindow.x)
    }

  }
}

private struct PinnedTile: View {
  let tab: BrowserTab
  let session: BrowserSession?
  let selected: Bool
  let side: CGFloat
  let onSelect: () -> Void
  let onClose: () -> Void
  let onPinInSpace: () -> Void
  let onMakeTemporary: () -> Void

  var body: some View {
    Button(action: onSelect) {
      TabFaviconView(
        pageURL: tab.url,
        session: session,
        size: 26,
        fallbackLetter: String((tab.url?.host ?? tab.displayTitle)
          .replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased())
        .frame(maxWidth: .infinity)
        .frame(height: side)
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }
    .buttonStyle(.plain)
    .browserChromeGlassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(selected ? 0.5 : 0.17), lineWidth: 1)
    }
    .shadow(color: .black.opacity(selected ? 0.18 : 0.06), radius: selected ? 13 : 5, y: selected ? 7 : 2)
    .scaleEffect(selected ? 1.02 : 1)
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

private struct SidebarTabRow: View {
  let tab: BrowserTab
  let session: BrowserSession?
  let selected: Bool
  let tier: WorkspaceCollection.TabTier
  let onSelect: () -> Void
  let onClose: () -> Void
  let onPinGlobally: () -> Void
  let onPinInSpace: () -> Void
  let onMakeTemporary: () -> Void
  @StateObject private var interaction = BrowserInteractionState()

  var body: some View {
    HStack(spacing: 0) {
      Button(action: onSelect) {
        HStack(spacing: 9) {
          TabFaviconView(pageURL: tab.url, session: session, size: 18)
            .frame(width: 20)
          Text(tab.displayTitle)
            .font(.callout.weight(selected ? .semibold : .regular))
            .lineLimit(1)
          Spacer(minLength: 0)
          if tab.isLoading {
            ProgressView().controlSize(.mini)
          }
        }
        .padding(.leading, 11)
        .frame(maxWidth: .infinity, minHeight: 36)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .frame(width: 29, height: 32)
      }
      .buttonStyle(.plain)
      .opacity(interaction.isHovered || selected ? 0.7 : 0)
      .allowsHitTesting(interaction.isHovered || selected)
      .help("Close Tab")
    }
    .padding(.trailing, 3)
    .background {
      if selected {
        Color.clear.browserChromeGlassSurface(in: RoundedRectangle(cornerRadius: 11, style: .continuous))
      } else if interaction.isHovered {
        RoundedRectangle(cornerRadius: 11).fill(.primary.opacity(0.06))
      }
    }
    .overlay {
      if selected {
        RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.35), lineWidth: 1)
      }
    }
    .shadow(color: .black.opacity(selected ? 0.15 : 0), radius: 8, y: 4)
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
