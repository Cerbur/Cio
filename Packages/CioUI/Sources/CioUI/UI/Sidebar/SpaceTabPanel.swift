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
  var containerFeedback: @MainActor (BrowserDragHaptics.Feedback) -> Void = BrowserDragHaptics.perform
  @ViewBuilder let content: (SpaceTabPanelRow) -> Content
  @ViewBuilder let tabContent: (SpaceTabPanelRow, UUID) -> TabContent
  @ViewBuilder let rowBackground: (SpaceTabPanelRow) -> RowBackground

  var body: some View {
    let layout = SidebarTabPanelLayout(rows: rows, columns: columns, rowHeight: rowHeight,
      rowSpacing: rowSpacing, columnSpacing: columnSpacing)
    let items = SidebarTabPanelItem.make(rows)
    GeometryReader { geometry in
      let frames = layout.frames(width: geometry.size.width)
      ZStack(alignment: .topLeading) {
        ForEach(rows) { row in
          let frame = frames[.row(row.id)] ?? .zero
          rowBackground(row)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .opacity(drag.isExpandingIntoSplit ? 1 : (row.draggableTabID.map(drag.sourceOpacity) ?? 1))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(-1)
            .transition(.identity)
        }
        ForEach(items) { item in
          let frame = frames[item.id] ?? .zero
          itemContent(item)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .zIndex(item.tabID == nil ? 1 : 0)
            .transition(.identity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(height: layout.height)
    // Focus/title updates cannot restart a layout flight. Member order is part
    // of the destination, so swapping panes also moves their retained controls.
    .animation(drag.panelLayoutAnimation, value: layout.destinations)
    .onChange(of: layout.feedbackSnapshot) { previous, current in
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
        drag.register(row, frame: frame, token: token)
      }
      .onAppear {
        if let frame = lastFrame.value { drag.register(row, frame: frame, token: token) }
      }
      .onChange(of: row) { _, _ in
        // Identity survives a tier change, even when its geometry is equal.
        if let frame = lastFrame.value { drag.register(row, frame: frame, token: token) }
      }
      .onDisappear { drag.unregister(row, token: token) }
  }
}
