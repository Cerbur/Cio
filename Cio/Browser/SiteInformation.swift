import Foundation

/// A snapshot of the visible document, never an inference from HTTPS alone.
struct SiteInformation {
  enum Connection {
    case secure, unencrypted, invalidCertificate, mixedContent, unavailable, local

    var title: String {
      switch self {
      case .secure: "连接是安全的"
      case .unencrypted: "连接未加密"
      case .invalidCertificate: "证书无效"
      case .mixedContent: "连接并非完全安全"
      case .unavailable: "尚无法确认连接安全"
      case .local: "本地或浏览器页面"
      }
    }

    var symbol: String {
      switch self {
      case .secure: "lock.fill"
      case .unencrypted, .invalidCertificate, .mixedContent: "exclamationmark.shield"
      case .unavailable: "shield.lefthalf.filled"
      case .local: "doc"
      }
    }

    var explanation: String {
      switch self {
      case .secure:
        "你与此网站之间传输的信息已通过 HTTPS 加密，Chromium 已验证网站证书。"
      case .unencrypted:
        "此网站使用 HTTP，传输的信息可能被他人读取或修改。请勿在此页面输入密码或银行卡信息。"
      case .invalidCertificate:
        "Chromium 无法验证此网站的证书，无法确认连接对象的身份。"
      case .mixedContent:
        "网站使用 HTTPS，但页面包含通过不安全连接加载的内容。部分信息可能被读取或修改。"
      case .unavailable:
        "页面尚未完成加载，或当前连接信息不可用。完成加载后可再次查看。"
      case .local:
        "此页面未使用网站的 HTTPS 连接，因此没有可供查看的网站证书。"
      }
    }
  }

  let url: URL?
  let title: String
  let connection: Connection
  let certificateValid: Bool
  let certificateChain: [Data]

  var host: String {
    guard let url else { return "网站信息" }
    if let host = url.host { return host + (url.port.map { ":\($0)" } ?? "") }
    return url.isFileURL ? "本地文件" : "浏览器页面"
  }

  init(url: URL?, title: String, isLoading: Bool, loadFailed: Bool,
       entryURL: URL?, usesTLS: Bool, certificateValid: Bool,
       hasInsecureContent: Bool, certificateChain: [Data]) {
    self.url = url
    self.title = title
    let scheme = url?.scheme?.lowercased()
    let hasCurrentEntry = url != nil && url == entryURL && !isLoading
    self.certificateChain = hasCurrentEntry ? certificateChain : []
    self.certificateValid = hasCurrentEntry && certificateValid
    if scheme != "https" && scheme != "http" {
      connection = .local
    } else if isLoading {
      connection = .unavailable
    } else if scheme == "https", hasCurrentEntry, usesTLS, !certificateValid {
      connection = .invalidCertificate
    } else if loadFailed || !hasCurrentEntry {
      connection = .unavailable
    } else if scheme == "http" {
      connection = .unencrypted
    } else if !usesTLS || certificateChain.isEmpty {
      connection = .unavailable
    } else if hasInsecureContent {
      connection = .mixedContent
    } else {
      connection = .secure
    }
  }
}
