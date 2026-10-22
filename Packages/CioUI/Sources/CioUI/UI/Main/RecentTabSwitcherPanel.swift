import AppKit
import SwiftUI

public struct RecentTabPage: Identifiable {
  public let id: UUID
  public let title: String
  public let host: String
  public let favicon: NSImage?
  public let preview: NSImage?

  public init(id: UUID, title: String, host: String, favicon: NSImage?, preview: NSImage?) {
    self.id = id; self.title = title; self.host = host
    self.favicon = favicon; self.preview = preview
  }
}

public struct RecentTabCandidate {
  public let id: UUID
  public let pages: [RecentTabPage]
  public var title: String { pages.map(\.title).joined(separator: " · ") }
  public var host: String { pages.map(\.host).joined(separator: " · ") }

  public init(id: UUID, pages: [RecentTabPage]) {
    self.id = id; self.pages = pages
  }

  public init(id: UUID, title: String, host: String, favicon: NSImage?, preview: NSImage?) {
    self.init(id: id, pages: [RecentTabPage(id: id, title: title, host: host, favicon: favicon, preview: preview)])
  }
}

/// One geometry source for the native window and its SwiftUI content. No footer
/// or estimated extra height: the cards have identical insets on all four sides.
public struct RecentTabSwitcherLayout {
  public static let outerInset: CGFloat = 12
  static let spacing: CGFloat = 8
  static let cardInset: CGFloat = 8
  static let metadataHeight: CGFloat = 34
  static let metadataSpacing: CGFloat = 7
  public let size: NSSize
  public let cardWidth: CGFloat
  public let previewHeight: CGFloat
  public var cardHeight: CGFloat { size.height - 2 * Self.outerInset }
  public let count: Int

  public init(count: Int, availableWidth: CGFloat) {
    self.count = max(1, count)
    let gaps = CGFloat(self.count - 1) * Self.spacing
    let width = min(availableWidth, CGFloat(self.count) * 174 + 2 * Self.outerInset + gaps)
    cardWidth = (width - 2 * Self.outerInset - gaps) / CGFloat(self.count)
    previewHeight = max(0, cardWidth - 2 * Self.cardInset) * 0.625
    size = NSSize(width: width, height: previewHeight + Self.metadataSpacing
      + Self.metadataHeight + 2 * Self.cardInset + 2 * Self.outerInset)
  }

  public var cardFrames: [NSRect] {
    (0..<count).map { index in
      NSRect(x: Self.outerInset + CGFloat(index) * (cardWidth + Self.spacing),
             y: Self.outerInset, width: cardWidth, height: cardHeight)
    }
  }
}

@MainActor
private final class RecentTabsPresentation: ObservableObject {
  @Published var candidates: [RecentTabCandidate] = []
  @Published var selectedID: UUID?
  @Published var isVisible = false
  @Published var isContentVisible = false
  @Published var layout = RecentTabSwitcherLayout(count: 1, availableWidth: 800)
  @Published var renderInset: CGFloat = 0
  var onSelect: ((UUID) -> Void)?
}

private struct RecentTabsView: View {
  @ObservedObject private var themes = BrowserThemePreferences.shared
  @ObservedObject var presentation: RecentTabsPresentation

  var body: some View {
    let layout = presentation.layout
    HStack(spacing: RecentTabSwitcherLayout.spacing) {
      ForEach(presentation.candidates, id: \.id) { candidate in
        Button { presentation.onSelect?(candidate.id) } label: {
          VStack(spacing: RecentTabSwitcherLayout.metadataSpacing) {
            HStack(spacing: 2) {
              ForEach(candidate.pages) { page in
                ZStack {
                  Color(nsColor: .textBackgroundColor)
                  if let image = page.preview {
                    GeometryReader { geometry in
                      // Each split pane fills its own slot proportionally.
                      // Constrain and clip before composing the panes so a
                      // wider/taller capture cannot resize or cover a neighbor.
                      Image(nsImage: image).resizable()
                        .aspectRatio(contentMode: candidate.pages.count > 1 ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    }
                  } else {
                    Image(systemName: "globe").font(.title2).foregroundStyle(.secondary)
                  }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
              }
            }
            .frame(height: layout.previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: BrowserLayout.contentCornerRadius))
            .accessibilityLabel("页面预览")
            Group {
              if candidate.pages.count > 1 {
                // A split is one candidate. Its only visible label is a centered
                // row of favicons, in the same left-to-right order as its panes.
                HStack(spacing: 6) {
                  ForEach(candidate.pages) { page in favicon(page) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
              } else if let page = candidate.pages.first {
                VStack(alignment: .leading, spacing: 3) {
                  HStack(spacing: 5) {
                    favicon(page)
                    Text(page.title).font(.caption).lineLimit(1)
                  }
                  Text(page.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
            .frame(height: RecentTabSwitcherLayout.metadataHeight)
          }
          .padding(RecentTabSwitcherLayout.cardInset)
          .frame(width: layout.cardWidth, height: layout.cardHeight)
          .background(candidate.id == presentation.selectedID ? themes.active.highlight(for: .recentSelection) : .clear,
                      in: RoundedRectangle(cornerRadius: BrowserLayout.contentCornerRadius))
          .contentShape(RoundedRectangle(cornerRadius: BrowserLayout.contentCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.title)
        .accessibilityValue(candidate.id == presentation.selectedID ? "已选择" : "")
        .accessibilityHint(candidate.host)
        .accessibilityIdentifier("recent-tab-\(candidate.id.uuidString)")
        .help(candidate.title)
      }
    }
    .padding(RecentTabSwitcherLayout.outerInset)
    .frame(width: layout.size.width, height: layout.size.height)
    // Composite the entire content surface; native glass keeps materialize.
    .compositingGroup()
    .modifier(GlassComponentContentVisibility(isVisible: presentation.isContentVisible))
    .background { RecentTabsGlass(isVisible: presentation.isVisible) }
    .modifier(GlassComponentVisibility(isVisible: presentation.isVisible))
    .padding(presentation.renderInset)
    .allowsHitTesting(presentation.isContentVisible)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("最近使用的页面")
  }

  @ViewBuilder private func favicon(_ page: RecentTabPage) -> some View {
    if let image = page.favicon {
      Image(nsImage: image).resizable().scaledToFit().frame(width: 14, height: 14)
    } else {
      Image(systemName: "globe").frame(width: 14, height: 14)
    }
  }
}

private struct RecentTabsGlass: View {
  @ObservedObject private var themes = BrowserThemePreferences.shared
  let isVisible: Bool
  @Namespace private var glass
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GlassEffectContainer(spacing: 0) {
      if isVisible {
        Color.clear
          .glassEffect(themes.active.component(.recentTabs).glass(), in: RoundedRectangle(cornerRadius: BrowserLayout.contentCornerRadius))
          .modifier(ComponentGlassAppearance(theme: themes.active.component(.recentTabs)))
          .glassEffectID("recent-tabs", in: glass)
          .glassEffectTransition(reduceMotion ? .identity : .materialize)
      }
    }
    .allowsHitTesting(false)
  }
}

private final class RecentTabsWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// A child panel leaves the active browser and its native editor mounted and
/// focused. Only the switcher's bounded local event session handles input.
@MainActor
public final class RecentTabSwitcherPanel {
  private let presentation = RecentTabsPresentation()
  public let window: NSPanel
  private var flight = UUID()
  private var requestedVisible = false

  public init(onSelect: @escaping (UUID) -> Void) {
    let panel = RecentTabsWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // An NSPanel shadow follows its rectangular backing store, not the changing
    // glass mask. The native glass owns its outline/shadow during dispersion.
    panel.hasShadow = false
    panel.hidesOnDeactivate = true
    panel.animationBehavior = .none
    panel.title = "最近使用的页面"
    let host = NSHostingView(rootView: RecentTabsView(presentation: presentation))
    host.safeAreaRegions = []
    host.sizingOptions = []
    panel.contentView = host
    window = panel
    presentation.onSelect = onSelect
  }

  public func update(candidates: [RecentTabCandidate], selectedID: UUID?) {
    presentation.candidates = candidates
    presentation.selectedID = selectedID
  }

  public func present(in parent: NSWindow) {
    flight = UUID()
    requestedVisible = true
    layout(in: parent)
    parent.addChildWindow(window, ordered: .above)
    window.orderFront(nil)
    let token = flight
    DispatchQueue.main.async { [weak self] in
      guard let self, self.flight == token, self.requestedVisible else { return }
      self.setVisible(true)
    }
  }

  public func layout(in parent: NSWindow) {
    let available = max(1, parent.frame.width - 40)
    let fittingWidth = max(1, (available - 2 * AnimationValues.RecentTabs.blurOutset)
      / AnimationValues.GlassComponent.dispersedScale)
    let layout = RecentTabSwitcherLayout(count: presentation.candidates.count, availableWidth: fittingWidth)
    presentation.layout = layout
    let inset = AnimationValues.RecentTabs.renderInset(for: layout.size)
    presentation.renderInset = inset
    let renderSize = NSSize(width: layout.size.width + 2 * inset, height: layout.size.height + 2 * inset)
    window.setFrame(NSRect(x: parent.frame.midX - renderSize.width / 2,
                           y: parent.frame.midY - renderSize.height / 2,
                           width: renderSize.width, height: renderSize.height), display: true)
  }

  public func dismiss() {
    requestedVisible = false
    window.ignoresMouseEvents = true
    let token = flight
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    // Resolve both clocks together so a speed preference change cannot leave
    // an old content flight running inside a newer material retirement.
    let contentDuration = AnimationValues.RecentTabs.contentDismissDuration
    let surfaceDuration = AnimationValues.RecentTabs.visibilityDuration
    withAnimation(reduceMotion ? nil : .smooth(duration: contentDuration)) {
      presentation.isContentVisible = false
    }
    let animation: Animation? = reduceMotion ? nil : .smooth(duration: surfaceDuration)
    withAnimation(animation, completionCriteria: .removed) {
      presentation.isVisible = false
    } completion: { [weak self] in
      guard let self, self.flight == token, !self.requestedVisible else { return }
      self.window.parent?.removeChildWindow(self.window)
      self.window.orderOut(nil)
    }
  }

  private func setVisible(_ visible: Bool) {
    window.ignoresMouseEvents = !visible
    let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil
      : .smooth(duration: AnimationValues.RecentTabs.visibilityDuration)
    withAnimation(animation) {
      presentation.isVisible = visible
      presentation.isContentVisible = visible
    }
  }
}
