//
//  TabSidebarView.swift
//  NativeBrowser
//
//  Three durable tab tiers: workspace pins, Space pins and temporary tabs.
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

struct TabSidebarView: View {
  @ObservedObject var workspace: BrowserWorkspaceStore
  @EnvironmentObject private var runtime: ApplicationRuntime
  @EnvironmentObject private var chromeLayout: SidebarChromeLayout

  private func columns(for width: CGFloat) -> Int {
    width >= 365 ? 4 : (width >= 275 ? 3 : 2)
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        pinnedGrid(columns: columns(for: geometry.size.width), width: geometry.size.width)
          .padding(.horizontal, 12)
          .padding(.top, chromeLayout.topInset + 12)
          .padding(.bottom, 12)

        Rectangle().fill(.primary.opacity(0.09)).frame(height: 0.5)
          .padding(.horizontal, 14)

        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 10) {
              sectionTitle(workspace.selectedSpace?.name ?? "Space", symbol: "square.3.layers.3d", count: workspace.spacePinnedTabs.count)
              tierRows(workspace.spacePinnedTabs, tier: .space(workspace.selectedSpaceID))

              sectionTitle("Temporary", symbol: "clock.arrow.circlepath", count: workspace.temporaryTabs.count)
              Label("Idle auto-close · coming soon", systemImage: "hourglass")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
              tierRows(workspace.temporaryTabs, tier: .temporary(workspace.selectedSpaceID))

              Button {
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
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 18)
          }
          .onChange(of: workspace.selectedTabID) { _, id in
            guard let id, !workspace.globalPinnedTabs.contains(where: { $0.id == id }) else { return }
            withAnimation(.smooth(duration: 0.24)) { proxy.scrollTo(id, anchor: .center) }
          }
        }
        .frame(maxHeight: .infinity)

        footer
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.ultraThinMaterial)
      .background(SpaceSwipeMonitor { step in
        guard let index = workspace.spaces.firstIndex(where: { $0.id == workspace.selectedSpaceID }) else { return }
        let next = index + step
        guard workspace.spaces.indices.contains(next) else { return }
        withAnimation(.smooth(duration: 0.28)) {
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

  private func pinnedGrid(columns: Int, width: CGFloat) -> some View {
    let tileSide = (width - 24 - CGFloat(columns - 1) * 9) / CGFloat(columns)
    return VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text("PINNED")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .tracking(1.2)
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(workspace.globalPinnedTabs.count)/16")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 3)

      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: columns), spacing: 9) {
        ForEach(workspace.globalPinnedTabs) { tab in
          PinnedTile(tab: tab, selected: workspace.selectedTabID == tab.id, side: tileSide) {
            workspace.selectTab(id: tab.id)
          } onClose: {
            workspace.closeTab(id: tab.id)
          } onPinInSpace: {
            withAnimation(.smooth(duration: 0.28)) { _ = workspace.moveTab(tab.id, to: .space(workspace.selectedSpaceID)) }
          } onMakeTemporary: {
            withAnimation(.smooth(duration: 0.28)) { _ = workspace.moveTab(tab.id, to: .temporary(workspace.selectedSpaceID)) }
          }
          .draggable(tab.id.uuidString)
          .dropDestination(for: String.self) { items, _ in
            return move(items, to: .global, before: tab.id)
          }
        }
      }
      .animation(.smooth(duration: 0.28), value: workspace.globalPinnedTabs.map(\.id))

      if workspace.globalPinnedTabs.isEmpty {
        Text("Drag tabs here to keep them in every Space")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, minHeight: 58)
          .background {
            RoundedRectangle(cornerRadius: 17).strokeBorder(.primary.opacity(0.13), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
          }
      }
    }
    .dropDestination(for: String.self) { items, _ in
      return move(items, to: .global)
    }
    .help("Workspace pins stay visible when you switch Spaces")
  }

  private func sectionTitle(_ title: String, symbol: String, count: Int) -> some View {
    HStack(spacing: 6) {
      Image(systemName: symbol).frame(width: 16)
      Text(title).lineLimit(1)
      Spacer()
      Text("\(count)").monospacedDigit()
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 9)
  }

  private func tierRows(_ tabs: [BrowserTab], tier: WorkspaceCollection.TabTier) -> some View {
    VStack(spacing: 3) {
      ForEach(tabs) { tab in
        SidebarTabRow(tab: tab, selected: workspace.selectedTabID == tab.id, tier: tier) {
          workspace.selectTab(id: tab.id)
        } onClose: {
          workspace.closeTab(id: tab.id)
        } onPinGlobally: {
          withAnimation(.smooth(duration: 0.28)) { _ = workspace.moveTab(tab.id, to: .global) }
        } onPinInSpace: {
          withAnimation(.smooth(duration: 0.28)) { _ = workspace.moveTab(tab.id, to: .space(workspace.selectedSpaceID)) }
        } onMakeTemporary: {
          withAnimation(.smooth(duration: 0.28)) { _ = workspace.moveTab(tab.id, to: .temporary(workspace.selectedSpaceID)) }
        }
        .id(tab.id)
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
          return move(items, to: tier, before: tab.id)
        }
      }
      Color.clear.frame(height: tabs.isEmpty ? 24 : 10)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in return move(items, to: tier) }
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
        Text(workspace.selectedSpace?.name ?? "Space")
          .font(.caption.weight(.medium))
          .lineLimit(1)
          .foregroundStyle(.secondary)
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
  let selected: Bool
  let side: CGFloat
  let onSelect: () -> Void
  let onClose: () -> Void
  let onPinInSpace: () -> Void
  let onMakeTemporary: () -> Void

  var body: some View {
    Button(action: onSelect) {
      VStack(spacing: 5) {
        Text(String((tab.url?.host ?? tab.displayTitle).prefix(1)).uppercased())
          .font(.system(size: 23, weight: .semibold, design: .rounded))
          .foregroundStyle(selected ? Color.accentColor : .primary)
        Text(tab.url?.host ?? tab.displayTitle)
          .font(.system(size: 10, weight: .medium))
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: max(0, side - 20))
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .frame(height: side)
      .contentShape(RoundedRectangle(cornerRadius: 18))
    }
    .buttonStyle(.plain)
    .browserChromeGlassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(selected ? 0.5 : 0.17), lineWidth: 1)
    }
    .overlay(alignment: .topTrailing) {
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
        .draggable(tab.id.uuidString)
        .accessibilityLabel("Drag Tab")
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
          Image(systemName: tierSymbol)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 16)
            .foregroundStyle(selected ? Color.accentColor : .secondary)
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
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .opacity(interaction.isHovered || selected ? 0.8 : 0.35)
        .frame(width: 25, height: 32)
        .contentShape(Rectangle())
        .draggable(tab.id.uuidString)
        .help("Drag to reorder or pin")
        .accessibilityLabel("Drag Tab")
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

  private var tierSymbol: String {
    switch tier {
    case .global: "pin.fill"
    case .space: "pin"
    case .temporary: "globe"
    }
  }
}

/// Observes horizontal precision scrolling without consuming the normal
/// vertical scroll event used by the tab list.
private struct SpaceSwipeMonitor: NSViewRepresentable {
  let onStep: (Int) -> Void

  func makeNSView(context: Context) -> MonitorView {
    let view = MonitorView()
    view.onStep = onStep
    return view
  }

  func updateNSView(_ view: MonitorView, context: Context) {
    view.onStep = onStep
  }

  final class MonitorView: NSView {
    var onStep: ((Int) -> Void)?
    nonisolated(unsafe) private var monitor: Any?
    private var accumulated: CGFloat = 0
    private var triggered = false
    private var lastEventTime: TimeInterval = 0

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        self?.handle(event)
        return event
      }
    }

    deinit {
      if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func handle(_ event: NSEvent) {
      guard let window, event.window === window, event.hasPreciseScrollingDeltas else { return }
      let point = convert(event.locationInWindow, from: nil)
      guard bounds.contains(point) else { return }
      guard event.momentumPhase == [] else { return }
      if event.phase == .began || event.timestamp - lastEventTime > 0.5 {
        accumulated = 0
        triggered = false
      }
      lastEventTime = event.timestamp
      if event.phase == .ended || event.phase == .cancelled {
        accumulated = 0
        triggered = false
        return
      }
      guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.2, !triggered else { return }
      accumulated += event.scrollingDeltaX
      if abs(accumulated) >= 48 {
        triggered = true
        onStep?(accumulated > 0 ? 1 : -1)
      }
    }
  }
}
