import AppKit
import Combine
import SwiftUI

/// Presents shell UI without taking ownership of Chromium's install decision.
/// AppKit owns sheet modality and its animation; SwiftUI uses system glass,
/// typography, scrolling, buttons and accessibility.
@MainActor
public final class ExtensionInstallSheet {
  private let panel: InstallPanel
  private let state = InstallSheetState()
  private var observations = Set<AnyCancellable>()
  private var finished = false
  private var presented = false
  private let onCancel: () -> Void

  public init(name: String, permissionsHeading: String, permissions: [String],
              acceptLabel: String, cancelLabel: String,
              onAccept: @escaping () -> Void, onCancel: @escaping () -> Void) {
    self.onCancel = onCancel
    panel = InstallPanel(contentRect: .zero, styleMask: [.borderless],
                         backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    panel.title = "将“\(name)”添加到 Cio？"
    panel.onCancel = onCancel
    let content = ExtensionInstallContent(
      name: name, permissionsHeading: permissionsHeading, permissions: permissions,
      acceptLabel: acceptLabel, cancelLabel: cancelLabel, state: state,
      onAccept: onAccept, onCancel: onCancel)
    let host = NSHostingView(rootView: content)
    host.sizingOptions = [.preferredContentSize]
    panel.contentView = host
    panel.setContentSize(host.fittingSize)
  }

  public func present(in parent: NSWindow, onPresented: @escaping (NSWindow) -> Void) {
    // AppKit can queue sheets. Start input protection when this one actually
    // becomes key, rather than when the request entered the queue.
    NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification, object: panel)
      .sink { [weak self] _ in MainActor.assumeIsolated {
        guard let self, !self.presented, !self.finished else { return }
        self.presented = true
        onPresented(self.panel)
      }}.store(in: &observations)
    NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: parent)
      .sink { [weak self] _ in MainActor.assumeIsolated {
        self?.onCancel()
      }}.store(in: &observations)
    parent.beginSheet(panel) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.panel.orderOut(nil)
        if !self.finished { self.onCancel() }
      }
    }
  }

  public func setAcceptEnabled(_ enabled: Bool) { state.canAccept = enabled }

  public func dismiss() {
    guard !finished else { return }
    finished = true
    observations.removeAll()
    if let parent = panel.sheetParent {
      parent.endSheet(panel)
    }
    panel.orderOut(nil)
  }
}

@MainActor
private final class InstallPanel: NSPanel {
  var onCancel: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
private final class InstallSheetState: ObservableObject {
  @Published var canAccept = false
}

private struct ExtensionInstallContent: View {
  let name: String
  let permissionsHeading: String
  let permissions: [String]
  let acceptLabel: String
  let cancelLabel: String
  @ObservedObject var state: InstallSheetState
  let onAccept: () -> Void
  let onCancel: () -> Void

  private static let width: CGFloat = 380
  private static let padding: CGFloat = 24
  private static let rowSpacing: CGFloat = 12
  private static let permissionFont = NSFont.preferredFont(forTextStyle: .body)

  private var permissionHeight: CGFloat {
    let textWidth = Self.width - Self.padding * 2 - 20
    let height = permissions.reduce(CGFloat.zero) { result, permission in
      result + ceil((permission as NSString).boundingRect(
        with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: Self.permissionFont]).height)
    } + CGFloat(max(0, permissions.count - 1)) * Self.rowSpacing
    return min(240, height)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 16) {
        Image(systemName: "app.dashed")
          .foregroundStyle(.tint)
        Image(systemName: "arrow.left")
          .font(.body)
          .foregroundStyle(.tertiary)
        Image(systemName: "puzzlepiece.extension")
          .foregroundStyle(.secondary)
      }
      .font(.system(size: 36, weight: .regular))
      .symbolRenderingMode(.hierarchical)
      .frame(height: 48)
      .accessibilityHidden(true)

      Text("将“\(name)”添加到 Cio？")
        .font(.title3.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)

      if !permissions.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          Text(permissionsHeading)
            .font(.body.weight(.medium))
            .foregroundStyle(.secondary)
          ScrollView {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
              ForEach(permissions.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
                    .frame(width: 12)
                  Text(permissions[index])
                    .font(Font(Self.permissionFont))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
              }
            }
          }
          .scrollBounceBehavior(.basedOnSize)
          .frame(height: permissionHeight)
        }
      }

      HStack(spacing: 12) {
        Spacer(minLength: 0)
        Button(cancelLabel, action: onCancel)
          .buttonStyle(.glass)
          .keyboardShortcut(.defaultAction)
        Button(acceptLabel, action: onAccept)
          .buttonStyle(.glassProminent)
          .disabled(!state.canAccept)
      }
      .controlSize(.large)
    }
    .padding(Self.padding)
    .frame(width: Self.width)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    .onExitCommand(perform: onCancel)
    .ignoresSafeArea()
  }
}
