import CioEngine
import AppKit
import SwiftUI

/// One favicon renderer for top pin, space pin and temporary tabs. A live
/// session supplies Chromium's decoded artwork; a lazily restored tab displays
/// its persisted artwork without creating a browser session or network request.
struct TabFaviconView: View {
  let pageURL: URL?
  let session: (any BrowserSessionProtocol)?
  let size: CGFloat
  let fallbackLetter: String?
  let cachedData: Data?

  init(pageURL: URL?, session: (any BrowserSessionProtocol)?, size: CGFloat,
       fallbackLetter: String? = nil, cachedData: Data? = nil) {
    self.pageURL = pageURL
    self.session = session
    self.size = size
    self.fallbackLetter = fallbackLetter
    self.cachedData = cachedData
  }

  var body: some View {
    if let session {
      LiveTabFaviconView(session: session, pageURL: pageURL,
                         size: size, fallbackLetter: fallbackLetter)
    } else if let cachedData, let raster = BrowserArtwork.decode(cachedData, as: .favicon) {
      FaviconArtworkView(image: NSImage(cgImage: raster, size: .zero), size: size, fallbackLetter: fallbackLetter)
    } else {
      ResolvedTabFaviconView(pageURL: pageURL, preferredURLs: [],
                             size: size, fallbackLetter: fallbackLetter)
    }
  }
}

private struct LiveTabFaviconView: View {
  @ObservedEngine var session: any BrowserSessionProtocol
  let pageURL: URL?
  let size: CGFloat
  let fallbackLetter: String?

  var body: some View {
    FaviconArtworkView(image: session.faviconImage, size: size, fallbackLetter: fallbackLetter)
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
    FaviconArtworkView(image: image, size: size, fallbackLetter: fallbackLetter)
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

private struct FaviconArtworkView: View {
  let image: NSImage?
  let size: CGFloat
  let fallbackLetter: String?

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
  }
}

