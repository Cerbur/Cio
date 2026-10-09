import Combine
import Foundation
import CioModel

/// UI access to the original App-owned workspace and its existing policies.
/// Native surface operations are supplied separately by CioUI's SurfaceDriver.
@MainActor
public protocol BrowserWorkspaceProtocol: BrowserEngineObservable {
  var spaces: [BrowserSpace] { get }
  var selectedSpaceID: UUID { get }
  var selectedSpace: BrowserSpace? { get }
  var selectedTabID: UUID? { get }
  var globalPinnedTabs: [BrowserTab] { get }
  var activeSplit: BrowserSplitLayout? { get }

  var isSpotlightPresented: Bool { get }
  var isSpotlightPresentedPublisher: AnyPublisher<Bool, Never> { get }

  /// Separate projection names preserve the App's concrete session API.
  var engineSelectedSession: (any BrowserSessionProtocol)? { get }
  func browserSession(for tabID: UUID) -> (any BrowserSessionProtocol)?

  func tab(withID id: UUID) -> BrowserTab?
  func splitGroup(containing tabID: UUID) -> BrowserSplitLayout?

  @discardableResult
  func createSpace(name: String?) -> UUID?

  @discardableResult
  func renameSpace(id: UUID, name: String) -> Bool

  func selectSpace(id: UUID)
  func selectTab(id: UUID, focusingPage: Bool)
  func closeTab(id: UUID)
  func clearTemporaryTabs(in spaceID: UUID)
  func presentSpotlight()

  @discardableResult
  func loadInSelectedTab(_ url: URL) -> Bool

  /// Sidebar drops stay in the background; right-edge drops join the visible group.
  @discardableResult
  func openDroppedWebPage(_ url: URL, before tabID: UUID?, splittingOnRight: Bool) -> UUID?

  @discardableResult
  func moveTab(
    _ id: UUID,
    to tier: WorkspaceCollection.TabTier,
    before targetID: UUID?
  ) -> Bool

  @discardableResult
  func moveSplitGroup(
    containing tabID: UUID,
    to tier: WorkspaceCollection.TabTier,
    before targetID: UUID?
  ) -> Bool

  func spacePinToggleTarget(for id: UUID)
    -> (tier: WorkspaceCollection.TabTier, before: UUID?)?

  func canSplit(with tabID: UUID) -> Bool

  @discardableResult
  func splitTab(_ tabID: UUID, at target: BrowserSplitLayout.DropTarget) -> Bool

  func detachSplitPane(_ tabID: UUID, selectDetached: Bool)

  @discardableResult
  func moveSplitPane(
    _ tabID: UUID,
    to tier: WorkspaceCollection.TabTier,
    before targetID: UUID?
  ) -> Bool

  @discardableResult
  func reorderSplitPane(_ tabID: UUID, to index: Int) -> Bool

  func setSplitFraction(_ fraction: CGFloat, divider: Int)
  func ungroupSplit(containing tabID: UUID)
  func swapSplitSides(containing tabID: UUID)
}

public extension BrowserWorkspaceProtocol {
  @discardableResult
  func createSpace() -> UUID? {
    createSpace(name: nil)
  }

  func selectTab(id: UUID) {
    selectTab(id: id, focusingPage: false)
  }

  func detachSplitPane(_ tabID: UUID) {
    detachSplitPane(tabID, selectDetached: false)
  }

  func setSplitFraction(_ fraction: CGFloat) {
    setSplitFraction(fraction, divider: 0)
  }

  @discardableResult
  func moveTab(_ id: UUID, to tier: WorkspaceCollection.TabTier) -> Bool {
    moveTab(id, to: tier, before: nil)
  }

  @discardableResult
  func moveSplitGroup(
    containing tabID: UUID,
    to tier: WorkspaceCollection.TabTier
  ) -> Bool {
    moveSplitGroup(containing: tabID, to: tier, before: nil)
  }

  @discardableResult
  func moveSplitPane(_ tabID: UUID, to tier: WorkspaceCollection.TabTier) -> Bool {
    moveSplitPane(tabID, to: tier, before: nil)
  }
}
