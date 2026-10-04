import SwiftUI

/// Every element shares this layout and movement path. The container has no
/// material or hover behavior; those belong to the elements it presents.
struct SpaceTabPanel<Content: View>: View {
  let rows: [SpaceTabPanelRow]
  let drag: SidebarTabDrag
  @ViewBuilder let content: (SpaceTabPanelRow) -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: BrowserLayout.sidebarRowSpacing) {
      ForEach(rows) { row in
        SpaceTabRowContainer(row: row, drag: drag) { content(row) }
      }
    }
    .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: rows)
  }
}

private struct SpaceTabRowContainer<Content: View>: View {
  let row: SpaceTabPanelRow
  let drag: SidebarTabDrag
  @ViewBuilder let content: () -> Content
  @State private var token = UUID()
  @State private var lastFrame = LastFrame()

  private final class LastFrame { var value: CGRect? }
  private var opacity: Double { row.draggableTabID.map(drag.sourceOpacity) ?? 1 }

  var body: some View {
    content()
      .frame(maxWidth: .infinity)
      .frame(height: BrowserLayout.sidebarTabRowHeight)
      .environment(\.sidebarTabPresentation, SidebarTabPresentation(
        isDragged: row.draggableTabID == drag.tabID && drag.tabID != nil))
      // Hiding the original container is structural. Materialization/fades
      // are handled by the Tab when it enters the floating presentation.
      .opacity(opacity)
      .animation(nil, value: opacity)
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
