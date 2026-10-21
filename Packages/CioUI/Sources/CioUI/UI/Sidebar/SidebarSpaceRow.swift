import CioModel
import SwiftUI

struct SidebarSpaceRow: View {
  let space: BrowserSpace
  let isCollapsed: Bool
  let isTabDragActive: Bool
  let onToggle: () -> Void
  let onChangeIcon: (BrowserSpaceIcon) -> Void
  @State private var isHovered = false
  @State private var isPickerPresented = false
  @State private var isMenuHovered = false
  @FocusState private var isMenuFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var showsDisclosure: Bool { isCollapsed || (isHovered && !isTabDragActive) }
  private var showsMenu: Bool { !isTabDragActive && (isHovered || isMenuFocused || isPickerPresented) }

  var body: some View {
    SidebarRowContainer(showsAction: showsMenu) {
      Button(action: onToggle) {
        SidebarRowLabel(title: space.name, titleWeight: .semibold) { size in
          ZStack {
            SpaceIconView(icon: space.icon, size: size)
              .opacity(showsDisclosure ? 0 : 1)
            Image(systemName: "chevron.right")
              .font(.system(size: BrowserLayout.sidebarTabDisclosureSymbolSize, weight: .semibold))
              .rotationEffect(.degrees(isCollapsed ? 0 : AnimationValues.Sidebar.spacePinExpandedDisclosureAngle))
              .animation(reduceMotion ? nil : AnimationValues.Sidebar.spacePinToggleAnimation,
                         value: isCollapsed)
              .opacity(showsDisclosure ? 1 : 0)
          }
          .frame(width: size, height: size)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
          .popover(isPresented: $isPickerPresented, arrowEdge: .top) {
            SpaceIconPicker(icon: space.icon) { icon in
              onChangeIcon(icon)
              isPickerPresented = false
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isTabDragActive)
      .help(isCollapsed ? "Expand Space Pins" : "Collapse Space Pins")
      .accessibilityLabel("Space: \(space.name)")
      .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
      .accessibilityIdentifier("space-row-\(space.id.uuidString)")
    } action: {
      Menu {
        Button("Change Space Icon…") { isPickerPresented = true }
      } label: {
        SidebarRowActionSymbol(name: "ellipsis", isHovered: showsMenu && isMenuHovered)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .focused($isMenuFocused)
      .disabled(isTabDragActive)
      .onHover { isMenuHovered = $0 }
      .help("Space options")
      .accessibilityLabel("Space options for \(space.name)")
      .accessibilityIdentifier("space-menu-\(space.id.uuidString)")
    }
    .frame(height: BrowserLayout.sidebarTabRowHeight)
    .foregroundStyle(.secondary)
    .background {
      if isHovered && !isTabDragActive {
        SidebarTabAppearance.glassShape.fill(.primary.opacity(0.06))
      }
    }
    .contentShape(SidebarTabAppearance.glassShape)
    .onHover { isHovered = $0 }
    .onChange(of: showsMenu) { _, shown in
      if !shown { isMenuHovered = false }
    }
    .contextMenu {
      Button("Change Space Icon…") { isPickerPresented = true }
    }
    .onChange(of: isTabDragActive) { _, active in
      if active { isPickerPresented = false }
    }
  }
}
