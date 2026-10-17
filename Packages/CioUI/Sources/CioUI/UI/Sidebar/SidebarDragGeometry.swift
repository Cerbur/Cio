import SwiftUI

private struct SidebarDragRegistrationEnabledKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  /// Only the active sidebar composition contributes drag geometry and feedback.
  var sidebarDragRegistrationEnabled: Bool {
    get { self[SidebarDragRegistrationEnabledKey.self] }
    set { self[SidebarDragRegistrationEnabledKey.self] = newValue }
  }
}

enum SidebarDragGeometryRegion: Equatable {
  case topPins
  case spaceArea
  case viewport(UUID)
  case header(UUID, isSelected: Bool)
}

extension View {
  func sidebarDragGeometry(_ region: SidebarDragGeometryRegion, drag: SidebarTabDrag) -> some View {
    modifier(SidebarDragGeometry(region: region, drag: drag))
  }
}

private struct SidebarDragGeometry: ViewModifier {
  let region: SidebarDragGeometryRegion
  let drag: SidebarTabDrag
  @Environment(\.sidebarDragRegistrationEnabled) private var registrationEnabled
  @State private var token = UUID()
  @State private var lastFrame = LastFrame()

  // Retain geometry without invalidating the view for every scrolling frame.
  private final class LastFrame { var value: CGRect? }

  func body(content: Content) -> some View {
    content
      .onSidebarFrameChange { frame in
        lastFrame.value = frame
        registerLatestFrame()
      }
      .onAppear { registerLatestFrame() }
      .onChange(of: registrationEnabled) { _, enabled in
        if enabled {
          registerLatestFrame()
        } else {
          unregister(region)
          if region == .topPins { drag.topPinFrame = .zero }
        }
      }
      .onChange(of: region) { previous, _ in
        unregister(previous)
        if registrationEnabled, previous == .topPins { drag.topPinFrame = .zero }
        // Selection can change while the header's geometry stays equal.
        registerLatestFrame()
      }
      .onDisappear { unregister(region) }
  }

  private func registerLatestFrame() {
    guard registrationEnabled, let frame = lastFrame.value else { return }
    switch region {
    case .topPins:
      drag.topPinFrame = frame
    case .spaceArea:
      drag.spaceFrame = frame
    case .viewport(let spaceID):
      drag.registerSpaceViewport(spaceID, frame: frame, token: token)
    case .header(let spaceID, let isSelected):
      drag.registerSpaceHeader(spaceID, frame: frame, token: token)
      if isSelected { drag.spaceHeaderFrame = frame }
    }
  }

  private func unregister(_ region: SidebarDragGeometryRegion) {
    switch region {
    case .viewport(let spaceID):
      drag.unregisterSpaceViewport(spaceID, token: token)
    case .header(let spaceID, _):
      drag.unregisterSpaceHeader(spaceID, token: token)
    case .topPins, .spaceArea:
      // Shared scalar frames are replaced by the active composition. In
      // particular, outgoing disappearance must not clear its replacement.
      break
    }
  }
}
