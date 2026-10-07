import AppKit
import CioEngine
import CioModel
import Foundation

/// CioUI's native presentation contract, implemented by the original App manager.
/// Inheriting BrowserEngineObservable allows ObservedEngine to observe that
/// manager's original publisher. CioEngine does not depend on this protocol.
@MainActor
public protocol BrowserSurfaceDriverProtocol: BrowserEngineObservable {
  /// App creates and configures the stable host, then attaches it to this driver.
  /// Host configuration and covered state precede attachment/CEF creation.
  func makeSurfaceHost(
    workspace: any BrowserWorkspaceProtocol,
    history: HistoryService,
    isCovered: Bool
  ) -> BrowserSurfaceHostView

  /// Idempotently re-adopts the same host during representable updates.
  func attachSurfaceHost(_ host: BrowserSurfaceHostView)

  var onSplitPaneDrag: ((UUID, BrowserSplitPaneDragEvent) -> Bool)? { get set }
  var onMinimizeSplitPane: ((UUID) -> Bool)? { get set }

  func beginPaneLift(_ id: UUID, to frame: CGRect)
  func holdPaneForSidebar(_ id: UUID) -> CGRect?
  func collapsePaneToSidebar(_ id: UUID, to frame: CGRect, duration: TimeInterval)
  func endPaneSidebarCollapse(_ id: UUID)
  func previewPaneDrag(_ tabID: UUID?, index: Int?)
  func previewSplit(
    at target: BrowserSplitLayout.DropTarget?,
    incomingPaneCount: Int
  )

  /// These closures remain synchronous and nonescaping. The original manager
  /// invokes the workspace mutation inside the current presentation handoff.
  func commitSplitPreview(
    keepingLiftedPaneHidden: Bool,
    _ commit: () -> Bool
  ) -> Bool
  func commitSplitDrop(_ commit: () -> Bool) -> Bool

  func splitLandingFrame(for tabIDs: [UUID]) -> CGRect?
  func revealSplitPages(
    for tabIDs: [UUID],
    from frame: CGRect,
    onCompletion: @escaping () -> Void
  )
}

public extension BrowserSurfaceDriverProtocol {
  /// Preserve BrowserSurfaceView's current isCovered = false default.
  func makeSurfaceHost(
    workspace: any BrowserWorkspaceProtocol,
    history: HistoryService
  ) -> BrowserSurfaceHostView {
    makeSurfaceHost(workspace: workspace, history: history, isCovered: false)
  }

  func previewPaneDrag(_ tabID: UUID?) {
    previewPaneDrag(tabID, index: nil)
  }

  func previewSplit(at target: BrowserSplitLayout.DropTarget?) {
    previewSplit(at: target, incomingPaneCount: 1)
  }

  func commitSplitPreview(_ commit: () -> Bool) -> Bool {
    commitSplitPreview(keepingLiftedPaneHidden: false, commit)
  }
}
