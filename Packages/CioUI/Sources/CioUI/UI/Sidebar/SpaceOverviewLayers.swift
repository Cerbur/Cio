import AppKit
import Combine
import SwiftUI

/// SwiftUI updates content at state boundaries. Native retained hosts consume
/// frame samples directly, so scrubbing never rebuilds either tab list.
struct SpaceOverviewLayers<Normal: View, Manager: View>: NSViewRepresentable {
  @ObservedObject var motion: SpaceOverviewLayoutMotion
  let isOverview: Bool
  @ViewBuilder let normal: (CGFloat) -> Normal
  @ViewBuilder let manager: () -> Manager

  func makeNSView(context: Context) -> SurfaceView {
    let view = SurfaceView()
    view.observation = motion.frames.sink { [weak view] pose in view?.present(pose) }
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ view: SurfaceView, context: Context) {
    let pose = motion.presentation
    let normalWidth = motion.isTransitioning || isOverview ? pose.normalWidth : view.bounds.width
    view.normal.rootView = AnyView(normal(normalWidth > 0 ? normalWidth : pose.normalWidth)
      .environment(\.sidebarDragRegistrationEnabled, !isOverview && !motion.isTransitioning)
      .allowsHitTesting(!isOverview && !motion.isTransitioning)
      .accessibilityHidden(isOverview || motion.isTransitioning))
    view.manager.rootView = AnyView(manager()
      .environment(\.sidebarDragRegistrationEnabled, isOverview && !motion.isTransitioning)
      .allowsHitTesting(isOverview && !motion.isTransitioning)
      .accessibilityHidden(!isOverview || motion.isTransitioning))
    view.isOverview = isOverview
    view.isTransitioning = motion.isTransitioning
    view.present(pose)
  }

  final class SurfaceView: NSView {
    let normal = NSHostingView(rootView: AnyView(EmptyView()))
    let manager = NSHostingView(rootView: AnyView(EmptyView()))
    private let normalContainer = NSView()
    private let managerContainer = NSView()
    var observation: AnyCancellable?
    var isOverview = false
    var isTransitioning = false
    private var pose = SpaceOverviewPresentation()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      clipsToBounds = true
      for (container, host) in [(managerContainer, manager), (normalContainer, normal)] {
        host.safeAreaRegions = []
        host.sizingOptions = []
        host.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.addSubview(host)
        addSubview(container)
      }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(_ pose: SpaceOverviewPresentation) {
      self.pose = pose
      placeSurfaces()
    }

    override func layout() {
      super.layout()
      placeSurfaces()
    }

    private func placeSurfaces() {
      let width = isTransitioning || isOverview ? pose.normalWidth : bounds.width
      let compensation = isTransitioning || isOverview ? bounds.width - pose.sidebarWidth : 0
      let normalFrame = CGRect(x: pose.normalOffset + compensation, y: 0, width: max(1, width), height: bounds.height)
      let managerFrame = CGRect(x: pose.overviewOffset + compensation, y: 0, width: pose.overviewWidth, height: bounds.height)
      if normalContainer.frame != normalFrame { normalContainer.frame = normalFrame }
      if managerContainer.frame != managerFrame { managerContainer.frame = managerFrame }
      let normalBounds = CGRect(origin: .zero, size: normalFrame.size)
      let managerBounds = CGRect(origin: .zero, size: managerFrame.size)
      if normal.frame != normalBounds { normal.frame = normalBounds }
      if manager.frame != managerBounds { manager.frame = managerBounds }
    }
  }
}
