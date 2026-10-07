import AppKit
import SwiftUI

/// One favicon renderer for top pin, space pin and temporary tabs. A live
/// session supplies Chromium's icon URLs; a lazily restored tab can still show
/// its origin's favicon without creating a browser session.
struct TabFaviconView: View {
  let pageURL: URL?
  let session: BrowserSession?
  let size: CGFloat
  let fallbackLetter: String?

  init(pageURL: URL?, session: BrowserSession?, size: CGFloat, fallbackLetter: String? = nil) {
    self.pageURL = pageURL
    self.session = session
    self.size = size
    self.fallbackLetter = fallbackLetter
  }

  var body: some View {
    if let session {
      LiveTabFaviconView(session: session, pageURL: pageURL,
                         size: size, fallbackLetter: fallbackLetter)
    } else {
      ResolvedTabFaviconView(pageURL: pageURL, preferredURLs: [],
                             size: size, fallbackLetter: fallbackLetter)
    }
  }
}

private struct LiveTabFaviconView: View {
  @ObservedObject var session: BrowserSession
  let pageURL: URL?
  let size: CGFloat
  let fallbackLetter: String?

  var body: some View {
    ResolvedTabFaviconView(pageURL: session.url ?? pageURL,
                           preferredURLs: session.faviconURLs,
                           size: size, fallbackLetter: fallbackLetter)
  }
}

private struct ResolvedTabFaviconView: View {
  let pageURL: URL?
  let preferredURLs: [URL]
  let size: CGFloat
  let fallbackLetter: String?
  @State private var image: NSImage?

  private var requestURLs: [URL] {
    var urls = preferredURLs.filter { $0.scheme == "https" || $0.scheme == "http" }
    if let pageURL,
       let scheme = pageURL.scheme?.lowercased(),
       scheme == "https" || scheme == "http",
       pageURL.host != nil {
      var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
      components?.user = nil
      components?.password = nil
      components?.path = "/favicon.ico"
      components?.query = nil
      components?.fragment = nil
      if let fallback = components?.url, !urls.contains(fallback) { urls.append(fallback) }
    }
    return urls
  }

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      } else if let fallbackLetter {
        Text(fallbackLetter)
          .font(.system(size: size * 0.9, weight: .semibold, design: .rounded))
      } else {
        Image(systemName: "globe")
          .resizable()
          .scaledToFit()
          .padding(1)
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .task(id: requestURLs) {
      image = nil
      for url in requestURLs {
        guard !Task.isCancelled else { return }
        if let data = await TabFaviconCache.shared.data(for: url),
           let resolved = NSImage(data: data) {
          image = resolved
          return
        }
      }
    }
  }
}

/// One request per icon URL, including when several restored tabs share a host.
private actor TabFaviconCache {
  static let shared = TabFaviconCache()

  private enum Entry {
    case image(Data)
    case missing
  }

  private var entries: [URL: Entry] = [:]
  private var pending: [URL: Task<Data?, Never>] = [:]

  func data(for url: URL) async -> Data? {
    if let entry = entries[url] {
      if case .image(let data) = entry { return data }
      return nil
    }
    if let task = pending[url] { return await task.value }

    let task = Task.detached(priority: .utility) { () -> Data? in
      var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad,
                               timeoutInterval: 8)
      request.setValue("image/*", forHTTPHeaderField: "Accept")
      do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              !data.isEmpty, data.count <= 1_000_000 else { return nil }
        return data
      } catch {
        return nil
      }
    }
    pending[url] = task
    let result = await task.value
    entries[url] = result.map(Entry.image) ?? .missing
    pending[url] = nil
    return result
  }
}

