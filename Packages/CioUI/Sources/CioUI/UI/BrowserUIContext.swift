import Combine
import CioEngine

/// The UI's stable access point to the original App-owned objects and actions.
/// Construct once in App and pass the original Runtime publisher directly.
@MainActor
public final class BrowserUIContext: @MainActor ObservableObject {
  public let objectWillChange: ObservableObjectPublisher

  public let workspaceStore: any BrowserWorkspaceProtocol
  public let historyService: HistoryService
  public let downloadManager: DownloadManager
  public let surfaceDriver: any BrowserSurfaceDriverProtocol

  /// The original Runtime's $presentedInternalPanel, erased without scheduling.
  public let presentedInternalPanelPublisher:
    AnyPublisher<BrowserInternalPanel?, Never>

  private let getPresentedInternalPanel: @MainActor () -> BrowserInternalPanel?
  private let setPresentedInternalPanel: @MainActor (BrowserInternalPanel?) -> Void
  private let showHistoryAction: @MainActor () -> Void
  private let showDownloadsAction: @MainActor () -> Void
  private let dismissSpotlightAction: @MainActor () -> Void
  private let performSpotlightActionHandler: @MainActor (SpotlightAction) -> Void
  private let noteMainWindowAppearedAction: @MainActor () -> Void

  /// Reads and writes the original Runtime property. No panel state is copied.
  public var presentedInternalPanel: BrowserInternalPanel? {
    get { getPresentedInternalPanel() }
    set { setPresentedInternalPanel(newValue) }
  }

  public init(
    objectWillChange: ObservableObjectPublisher,
    workspaceStore: any BrowserWorkspaceProtocol,
    historyService: HistoryService,
    downloadManager: DownloadManager,
    surfaceDriver: any BrowserSurfaceDriverProtocol,
    presentedInternalPanelPublisher: AnyPublisher<BrowserInternalPanel?, Never>,
    getPresentedInternalPanel: @escaping @MainActor () -> BrowserInternalPanel?,
    setPresentedInternalPanel: @escaping @MainActor (BrowserInternalPanel?) -> Void,
    showHistory: @escaping @MainActor () -> Void,
    showDownloads: @escaping @MainActor () -> Void,
    dismissSpotlight: @escaping @MainActor () -> Void,
    performSpotlightAction: @escaping @MainActor (SpotlightAction) -> Void,
    noteMainWindowAppeared: @escaping @MainActor () -> Void
  ) {
    self.objectWillChange = objectWillChange
    self.workspaceStore = workspaceStore
    self.historyService = historyService
    self.downloadManager = downloadManager
    self.surfaceDriver = surfaceDriver
    self.presentedInternalPanelPublisher = presentedInternalPanelPublisher
    self.getPresentedInternalPanel = getPresentedInternalPanel
    self.setPresentedInternalPanel = setPresentedInternalPanel
    self.showHistoryAction = showHistory
    self.showDownloadsAction = showDownloads
    self.dismissSpotlightAction = dismissSpotlight
    self.performSpotlightActionHandler = performSpotlightAction
    self.noteMainWindowAppearedAction = noteMainWindowAppeared
  }

  public func showHistory() {
    showHistoryAction()
  }

  public func showDownloads() {
    showDownloadsAction()
  }

  /// Matches BrowserUIContext.dismissSpotlight(): no arguments or defaults.
  /// App forwards to Runtime, which derives focusPage from its current panel.
  public func dismissSpotlight() {
    dismissSpotlightAction()
  }

  public func performSpotlightAction(_ action: SpotlightAction) {
    performSpotlightActionHandler(action)
  }

  public func noteMainWindowAppeared() {
    noteMainWindowAppearedAction()
  }
}
