import CioChromium
import CioUI
import Combine
import Foundation

/// Joins Chromium's one-shot request to the native shell sheet. Keeping both
/// alive here also covers queued sheets and engine-initiated cancellation.
@MainActor
final class ExtensionConfirmationCoordinator {
  private struct Pending {
    let request: NSObject
    let sheet: ExtensionConfirmationSheet
    let acceptance: AnyCancellable
  }
  private var pending: [ObjectIdentifier: Pending] = [:]
  private var observations = Set<AnyCancellable>()

  init() {
    NotificationCenter.default.publisher(for: Notification.Name("CioExtensionInstallRequested"))
      .sink { [weak self] notification in MainActor.assumeIsolated {
        guard let request = notification.object as? CioExtensionInstallRequest else { return }
        self?.present(request)
      }}.store(in: &observations)
    NotificationCenter.default.publisher(for: Notification.Name("CioExtensionInstallFinished"))
      .merge(with: NotificationCenter.default.publisher(for: Notification.Name("CioExtensionRemovalFinished")))
      .sink { [weak self] notification in MainActor.assumeIsolated {
        guard let request = notification.object as? NSObject else { return }
        self?.pending.removeValue(forKey: ObjectIdentifier(request))?.sheet.dismiss()
      }}.store(in: &observations)
    NotificationCenter.default.publisher(for: Notification.Name("CioExtensionRemovalRequested"))
      .sink { [weak self] notification in MainActor.assumeIsolated {
        guard let request = notification.object as? CioExtensionRemovalRequest else { return }
        self?.present(request)
      }}.store(in: &observations)
  }

  private func present(_ request: CioExtensionInstallRequest) {
    guard let parent = request.parentWindow else { request.cancel(); return }
    let sheet = ExtensionConfirmationSheet(
      name: request.extensionName, action: .install, permissionsHeading: request.permissionsHeading,
      permissions: request.permissions, acceptLabel: request.acceptLabel,
      cancelLabel: request.cancelLabel,
      onAccept: { _ in request.accept() }, onCancel: { request.cancel() })
    let acceptance = request.publisher(for: \.canAccept)
      .sink { [weak sheet] enabled in MainActor.assumeIsolated {
        sheet?.setAcceptEnabled(enabled)
      }}
    pending[ObjectIdentifier(request)] = Pending(request: request, sheet: sheet, acceptance: acceptance)
    sheet.present(in: parent) { request.didPresent(in: $0) }
  }

  private func present(_ request: CioExtensionRemovalRequest) {
    guard let parent = request.parentWindow else { request.cancel(); return }
    let sheet = ExtensionConfirmationSheet(
      name: request.extensionName, action: .remove, message: request.message,
      reportAbuseLabel: request.reportAbuseLabel,
      acceptLabel: "移除扩展", cancelLabel: "取消",
      onAccept: { request.accept(reportAbuse: $0) }, onCancel: { request.cancel() })
    let acceptance = request.publisher(for: \.canAccept)
      .sink { [weak sheet] enabled in MainActor.assumeIsolated {
        sheet?.setAcceptEnabled(enabled)
      }}
    pending[ObjectIdentifier(request)] = Pending(request: request, sheet: sheet, acceptance: acceptance)
    sheet.present(in: parent) { request.didPresent(in: $0) }
  }
}
