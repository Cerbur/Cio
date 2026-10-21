import SwiftUI

/// Structural rows register whole-container drag geometry; tab controls are
/// siblings keyed by tab ID, so a row/group change cannot unmount a survivor.
struct SpaceTabPanel<Content: View, TabContent: View, RowBackground: View>: View {
  let rows: [SpaceTabPanelRow]
  let drag: SidebarTabDrag
  var columns = 1
  var rowHeight = BrowserLayout.sidebarTabRowHeight
  var rowSpacing = BrowserLayout.sidebarRowSpacing
  var columnSpacing = BrowserLayout.sidebarTopPinSpacing
  var hiddenTabIDs: Set<UUID> = []
  var containerFeedback: @MainActor (BrowserDragHaptics.Feedback) -> Void = BrowserDragHaptics.perform
  @ViewBuilder let content: (SpaceTabPanelRow) -> Content
  @ViewBuilder let tabContent: (SpaceTabPanelRow, UUID) -> TabContent
  @ViewBuilder let rowBackground: (SpaceTabPanelRow) -> RowBackground
  @Environment(\.sidebarDragRegistrationEnabled) private var registrationEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let layout = SidebarTabPanelLayout(rows: rows, columns: columns, rowHeight: rowHeight,
      rowSpacing: rowSpacing, columnSpacing: columnSpacing, hiddenTabIDs: hiddenTabIDs)
    let items = SidebarTabPanelItem.make(rows)
    let motion = reduceMotion ? nil : drag.panelLayoutAnimation
    let revealMotion = reduceMotion ? nil : AnimationValues.Sidebar.spacePinToggleAnimation
    GeometryReader { geometry in
      let frames = layout.frames(width: geometry.size.width)
      ZStack(alignment: .topLeading) {
        ForEach(rows) { row in
          let frame = frames[.row(row.id)] ?? .zero
          rowBackground(row)
            .opacity(drag.isExpandingIntoSplit ? 1 : (row.draggableTabID.map(drag.sourceOpacity) ?? 1))
            .sidebarRowMotion(frame: frame, isHidden: layout.isHidden(row), hiddenTabIDs: hiddenTabIDs,
                              animation: motion, revealAnimation: revealMotion)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(-1)
            .transition(.identity)
        }
        ForEach(items) { item in
          let frame = frames[item.id] ?? .zero
          itemContent(item)
            .sidebarRowMotion(frame: frame, isHidden: layout.isHidden(item.row), hiddenTabIDs: hiddenTabIDs,
                              animation: motion, revealAnimation: revealMotion)
            .allowsHitTesting(!layout.isHidden(item.row))
            .accessibilityHidden(layout.isHidden(item.row))
            .environment(\.sidebarDragRegistrationEnabled, registrationEnabled && !layout.isHidden(item.row))
            .zIndex(item.tabID == nil ? 1 : 0)
            .transition(.identity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .modifier(SidebarPanelHeightMotion(height: layout.height))
    // Focus/title updates cannot restart a layout flight. Member order is part
    // of the destination, so swapping panes also moves their retained controls.
    .animation(reduceMotion ? nil : drag.panelLayoutAnimation, value: layout.destinations)
    .animation(reduceMotion ? nil : AnimationValues.Sidebar.spacePinToggleAnimation,
               value: hiddenTabIDs)
    .onChange(of: layout.feedbackSnapshot) { previous, current in
      guard registrationEnabled else { return }
      if let feedback = current.feedback(from: previous) { containerFeedback(feedback) }
    }
  }

  @ViewBuilder
  private func itemContent(_ item: SidebarTabPanelItem) -> some View {
    if let id = item.tabID {
      let isCollapseDestination = drag.isPaneCollapseDestination(id)
      let opacity = isCollapseDestination ? 0 : (drag.isExpandingIntoSplit ? 1
        : drag.sourceOpacity(of: item.row.draggableTabID ?? id))
      tabContent(item.row, id)
        .opacity(opacity)
        .animation(nil, value: opacity)
        .allowsHitTesting(!isCollapseDestination)
        .accessibilityHidden(isCollapseDestination)
    } else {
      SpaceTabRowContainer(row: item.row, drag: drag) { content(item.row) }
    }
  }
}

private struct SpaceTabRowContainer<Content: View>: View {
  let row: SpaceTabPanelRow
  let drag: SidebarTabDrag
  @ViewBuilder let content: () -> Content
  @Environment(\.sidebarDragRegistrationEnabled) private var registrationEnabled
  @State private var token = UUID()
  @State private var lastFrame = LastFrame()

  private final class LastFrame { var value: CGRect? }
  private var isCollapseDestination: Bool {
    guard case .tab(let id) = row.id else { return false }
    return drag.isPaneCollapseDestination(id)
  }
  private var opacity: Double {
    isCollapseDestination ? 0 : (drag.isExpandingIntoSplit ? 1
      : (row.draggableTabID.map(drag.sourceOpacity) ?? 1))
  }

  var body: some View {
    content()
      .frame(maxWidth: .infinity)
      .environment(\.sidebarTabPresentation, SidebarTabPresentation(
        isDragged: !drag.isMinimizingPane && row.draggableTabID == drag.tabID && drag.tabID != nil))
      // Hiding the original container is structural. Materialization/fades
      // are handled by the Tab when it enters the floating presentation.
      .opacity(opacity)
      .animation(nil, value: opacity)
      .background {
        if isCollapseDestination { SidebarTabDropSlot() }
      }
      .allowsHitTesting(!isCollapseDestination)
      .accessibilityHidden(isCollapseDestination)
      .transition(.identity)
      .onSidebarFrameChange { frame in
        lastFrame.value = frame
        guard registrationEnabled else { return }
        drag.register(row, frame: frame, token: token)
      }
      .onAppear {
        registerLatestFrame()
      }
      .onChange(of: registrationEnabled) { _, enabled in
        if enabled {
          registerLatestFrame()
        } else {
          drag.unregister(row, token: token)
        }
      }
      .onChange(of: row) { previous, _ in
        // Identity survives a tier change, even when its geometry is equal.
        drag.unregister(previous, token: token)
        registerLatestFrame()
      }
      .onDisappear { drag.unregister(row, token: token) }
  }

  private func registerLatestFrame() {
    guard registrationEnabled, let frame = lastFrame.value else { return }
    drag.register(row, frame: frame, token: token)
  }
}
