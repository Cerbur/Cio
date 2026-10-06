import AppKit
import Combine

/// Owns a page's complete split motion: presentation geometry, native glass,
/// content readiness and completion. Drag sources only supply their card frame;
/// insertion, replacement, reordering and cancellation use the same reveal.
@MainActor
final class BrowserSplitPageTransition {
  private weak var page: BrowserPagePresentation?
  private struct Flight {
    let token: UUID
    let frame: CGRect
    let direction: BrowserSplitRevealTransition.Direction
    let completion: SplitPageFlightCompletion
  }
  private var flight: Flight?
  private(set) var restoration: BrowserSplitRevealTransition.Geometry?
  private var glass: SplitPageGlassView?
  private var loadObservation: AnyCancellable?
  private var contentFadeToken: UUID?

  init(page: BrowserPagePresentation) { self.page = page }

  var frame: CGRect? { flight?.frame }
  var direction: BrowserSplitRevealTransition.Direction? { flight?.direction }
  var isAnimating: Bool { flight != nil }
  var isExiting: Bool { flight?.direction.isExit == true }
  var isReturning: Bool { restoration != nil || isExiting }
  var defersChrome: Bool { flight?.direction == .enter }

  /// Capture before cancelling or assigning a new render size. A survivor can
  /// reverse its layout flight without jumping to either model endpoint.
  func source(in pane: CGRect) -> BrowserSplitRevealTransition.Geometry {
    if let restoration { return restoration }
    guard let page, !page.viewport.isHidden,
          page.viewport.frame.width > 0, page.viewport.frame.height > 0,
          let layer = page.viewport.layer else {
      let size = BrowserSplitRevealTransition.cardSize
      let card = CGRect(x: pane.midX - size.width / 2, y: pane.midY - size.height / 2,
                        width: size.width, height: size.height)
      return .card(card, pane: pane, group: pane)
    }
    let rendered = page.viewport.frame
    let shown = layer.presentation() ?? layer
    let scale = CGSize(width: max(0.001, shown.transform.m11), height: max(0.001, shown.transform.m22))
    let pivot = CGPoint(x: layer.anchorPoint.x * rendered.width, y: layer.anchorPoint.y * rendered.height)
    let origin = CGPoint(x: rendered.minX + pivot.x + shown.transform.m41 - pivot.x * scale.width,
                         y: rendered.minY + pivot.y + shown.transform.m42 - pivot.y * scale.height)
    let crop = (shown.mask as? CAShapeLayer)?.path?.boundingBoxOfPath ?? page.viewport.bounds
    let glassOpacity = glass.flatMap { glass -> Float? in
      guard !glass.isHidden, let layer = glass.layer else { return nil }
      return (layer.presentation() ?? layer).opacity
    } ?? 0
    return .init(center: CGPoint(x: origin.x + rendered.width / 2 * scale.width,
                                 y: origin.y + rendered.height / 2 * scale.height),
      outline: CGRect(x: origin.x + crop.minX * scale.width, y: origin.y + crop.minY * scale.height,
                      width: crop.width * scale.width, height: crop.height * scale.height),
      scale: scale, renderSize: rendered.size, glassOpacity: glassOpacity, opacity: shown.opacity)
  }

  func reveal(from card: CGRect, into pane: CGRect, group: CGRect, onCompletion: @escaping () -> Void) {
    animate(in: pane, from: .card(card, pane: pane, group: group), to: .page(pane),
            direction: .enter, onCompletion: onCompletion)
  }

  /// The same departure for split switches, replacements and preview eviction.
  /// Freeze Chromium at its current render size and capture any interrupted
  /// flight before fading; only an explicit lift/collapse travels to a card.
  func dismiss(onCompletion: @escaping () -> Void) {
    guard let page, !page.viewport.isHidden, !isExiting, restoration == nil,
          page.viewport.frame.width > 0, page.viewport.frame.height > 0 else { return }
    let pane = page.viewport.frame
    let initial = source(in: pane)
    page.toolbar?.setPageControlsVisible(false, animated: true)
    animate(in: pane, from: initial, to: .dismissedPage(pane),
            direction: .dismiss, onCompletion: onCompletion)
  }

  func animate(in pane: CGRect, from initial: BrowserSplitRevealTransition.Geometry,
               to destination: BrowserSplitRevealTransition.Geometry,
               direction: BrowserSplitRevealTransition.Direction, onCompletion: @escaping () -> Void) {
    guard let page, let layer = page.viewport.layer, pane.width > 0, pane.height > 0 else {
      onCompletion()
      return
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    cancel()
    let token = UUID()
    let completion = SplitPageFlightCompletion { [weak self, weak page] in
      guard let self, let page, self.flight?.token == token else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      defer { CATransaction.commit() }
      self.clearFlight(preservingPendingContent: direction == .enter)
      if direction.isExit {
        // A completed dismissal is hidden, not a parked near-full-size page.
        // Its next entry uses the normal glass-card pose; an interrupted
        // dismissal still resumes from the live presentation captured above.
        self.restoration = direction == .dismiss ? nil : destination
        page.hide(animated: false)
        page.surface.setSurfaceVisible(false)
      }
      onCompletion()
    }
    flight = Flight(token: token, frame: pane, direction: direction, completion: completion)
    let initial = initial.rebased(to: pane.size)
    let destination = destination.rebased(to: pane.size)
    page.viewport.frame = pane
    page.viewport.isHidden = false
    page.surface.setSurfaceVisible(true)
    let surfaceFrame = CGRect(origin: .zero, size: pane.size)
    if page.surface.frame != surfaceFrame { page.surface.frame = surfaceFrame }
    layer.zPosition = direction == .dismiss ? 0 : 1
    page.splitControl.isHidden = true
    if initial.glassOpacity > 0 || destination.glassOpacity > 0 {
      beginGlass(direction: direction, from: initial.glassOpacity, to: destination.glassOpacity)
    }
    BrowserSplitRevealTransition.animate(layer: layer, pane: pane, from: initial, to: destination,
                                        direction: direction, completion: completion)
  }

  func cancel() {
    clearFlight()
    restoration = nil
  }

  private func clearFlight(preservingPendingContent: Bool = false) {
    flight = nil
    hideGlass(preservingPendingContent: preservingPendingContent)
    guard let layer = page?.viewport.layer else { return }
    layer.removeAnimation(forKey: "split-reveal-transform")
    layer.removeAnimation(forKey: "split-reveal-opacity")
    layer.mask = nil
    layer.zPosition = 0
  }

  private func beginGlass(direction: BrowserSplitRevealTransition.Direction, from: Float, to: Float) {
    guard let page else { return }
    let glass: SplitPageGlassView
    if let existing = self.glass {
      glass = existing
    } else {
      glass = SplitPageGlassView(frame: page.viewport.bounds)
      glass.style = .regular
      glass.wantsLayer = true
      glass.setAccessibilityElement(false)
      page.viewport.addSubview(glass, positioned: .above, relativeTo: page.surface)
      self.glass = glass
    }
    // Keep material and Chromium at their render size for the whole flight.
    // Their shared viewport supplies the animated transform and rounded crop.
    glass.frame = page.viewport.bounds
    glass.cornerRadius = BrowserLayout.contentCornerRadius
    glass.isHidden = false
    guard let layer = glass.layer else { return }
    if direction == .enter, let session = page.surface.delegate as? BrowserSession,
       !session.hasFinishedFirstLoad {
      // Only a newly created runtime needs to wait for its initial content.
      // Moving an already rendered pane follows the normal glass dissolve.
      layer.opacity = from
      page.surface.layer?.opacity = 0
      loadObservation = session.$hasFinishedFirstLoad
        .combineLatest(session.$rendererCrashed)
        .map { finished, crashed in finished || crashed }
        .filter { $0 }
        .merge(with: Just(true).delay(
          for: .seconds(BrowserSplitRevealTransition.contentWaitDuration), scheduler: RunLoop.main))
        .prefix(1)
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.revealLoadedContent() }
      return
    }
    layer.opacity = to
    let fade = BrowserSplitRevealTransition.glassOpacityAnimation(direction, from: from, to: to)
    fade.beginTime = 0
    layer.add(fade, forKey: "split-reveal-glass-fade")
  }

  private func revealLoadedContent() {
    guard loadObservation != nil, let glassLayer = glass?.layer else { return }
    loadObservation = nil
    let token = UUID()
    contentFadeToken = token
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock { [weak self] in
      DispatchQueue.main.async {
        guard let self, self.contentFadeToken == token else { return }
        self.hideGlass()
      }
    }
    for (layer, opacity) in [(glassLayer, Float(0)), (page?.surface.layer, Float(1))] {
      guard let layer else { continue }
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = (layer.presentation() ?? layer).opacity
      fade.toValue = opacity
      fade.duration = BrowserSplitRevealTransition.contentFadeDuration
      fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer.opacity = opacity
      layer.add(fade, forKey: "split-reveal-content-fade")
    }
    CATransaction.commit()
  }

  func hideGlass(preservingPendingContent: Bool = false) {
    if preservingPendingContent, loadObservation != nil || contentFadeToken != nil { return }
    loadObservation = nil
    contentFadeToken = nil
    page?.surface.layer?.removeAnimation(forKey: "split-reveal-content-fade")
    page?.surface.layer?.opacity = 1
    glass?.layer?.removeAnimation(forKey: "split-reveal-glass-fade")
    glass?.layer?.removeAnimation(forKey: "split-reveal-content-fade")
    glass?.isHidden = true
  }
}

/// Complete on this page's compositor clock rather than a transaction shared
/// with siblings. A longer sibling flight cannot leave outgoing glass around.
@MainActor
private final class SplitPageFlightCompletion: NSObject, CAAnimationDelegate {
  private let completion: @MainActor () -> Void
  init(_ completion: @escaping @MainActor () -> Void) { self.completion = completion }
  nonisolated func animationDidStop(_ animation: CAAnimation, finished: Bool) {
    guard finished else { return }
    Task { @MainActor [weak self] in self?.completion() }
  }
}

private final class SplitPageGlassView: NSGlassEffectView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
