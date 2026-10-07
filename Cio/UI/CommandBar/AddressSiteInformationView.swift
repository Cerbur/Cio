import AppKit
import SwiftUI

@MainActor
final class AddressSiteInformationState: ObservableObject {
  enum Page: Hashable { case overview, security }
  static let contentHeight: CGFloat = 260
  @Published private(set) var information: SiteInformation?
  @Published var page = Page.overview
  var isPresented: Bool { information != nil }

  func present(_ information: SiteInformation) {
    page = .overview
    self.information = information
  }

  func refresh(_ information: SiteInformation) {
    guard isPresented else { return }
    self.information = information
  }

  func dismiss() { information = nil }

  func width(in availableWidth: CGFloat, focused: Bool) -> CGFloat {
    let idle = availableWidth * AddressCapsuleLayout.unfocusedWidthRatio
      / AddressCapsuleLayout.focusedWidthRatio
    return focused ? availableWidth : isPresented ? max(idle, min(360, availableWidth)) : idle
  }

  func height(rowCount: Int) -> CGFloat {
    isPresented ? AddressCapsuleLayout.height + Self.contentHeight
      : AddressCapsuleLayout.panelHeight(rowCount: rowCount)
  }
}

/// Lives inside the address capsule's existing glass, so opening it changes
/// the shape of one native material instead of stacking a second backdrop.
struct AddressSiteInformationView: View {
  @ObservedObject var state: AddressSiteInformationState
  let onCertificate: (SiteInformation) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if let information = state.information {
      VStack(alignment: .leading, spacing: 16) {
        header(information)
        Divider()
        Group {
          if state.page == .overview {
            overview(information)
          } else {
            security(information)
          }
        }
        .id(state.page)
        .transition(.opacity)
        Spacer(minLength: 0)
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: AddressSiteInformationState.contentHeight, alignment: .top)
      .animation(reduceMotion ? nil : .easeInOut(duration: AnimationValues.AddressField.informationPageDuration), value: state.page)
      .accessibilityIdentifier("address-site-information")
    }
  }

  private func header(_ information: SiteInformation) -> some View {
    HStack(alignment: .top, spacing: 12) {
      if state.page == .security {
        iconButton("arrow.left", label: "返回网站信息", identifier: "site-information-back") {
          state.page = .overview
        }
      }
      VStack(alignment: .leading, spacing: 5) {
        Text(state.page == .overview ? information.host : "连接安全")
          .font(.system(size: 17, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.middle)
          .help(information.host)
        Text(state.page == .overview
             ? (information.title.isEmpty ? "网站信息" : information.title) : information.host)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func overview(_ information: SiteInformation) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Button { state.page = .security } label: {
        HStack(spacing: 12) {
          connectionIcon(information)
          Text(information.connection.title).font(.system(size: 14, weight: .medium))
          Spacer(minLength: 0)
          Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("site-information-security")
      Text("连接安全信息用于说明数据传输和网站身份验证情况，并不保证网站内容可信。")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 2)
    }
  }

  private func security(_ information: SiteInformation) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 12) {
        connectionIcon(information)
        VStack(alignment: .leading, spacing: 6) {
          Text(information.connection.title).font(.system(size: 14, weight: .semibold))
          Text(information.connection.explanation)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Button { onCertificate(information) } label: {
        HStack(spacing: 12) {
          Image(systemName: "checkmark.seal")
            .font(.system(size: 18)).frame(width: 22)
          Text(information.certificateChain.isEmpty ? "没有可查看的证书"
               : information.certificateValid ? "证书有效" : "查看证书")
            .font(.system(size: 13, weight: .medium))
          Spacer(minLength: 0)
          if !information.certificateChain.isEmpty {
            Image(systemName: "arrow.up.right.square").font(.system(size: 15))
          }
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
      }
      .buttonStyle(.plain)
      .disabled(information.certificateChain.isEmpty)
      .accessibilityIdentifier("site-information-certificate")
    }
  }

  private func connectionIcon(_ information: SiteInformation) -> some View {
    Image(systemName: information.connection.symbol)
      .font(.system(size: 18, weight: .medium))
      .foregroundStyle(information.connection == .secure ? Color.primary : Color.secondary)
      .frame(width: 22)
      .accessibilityHidden(true)
  }

  private func iconButton(_ symbol: String, label: String, identifier: String,
                          action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 26, height: 26)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
    .accessibilityIdentifier(identifier)
  }
}
