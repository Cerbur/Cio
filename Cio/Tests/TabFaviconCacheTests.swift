import CioEngine
@testable import CioUI
import CoreGraphics
import XCTest

private actor FaviconRequestCounts {
  private var counts: [URL: Int] = [:]
  func record(_ url: URL) { counts[url, default: 0] += 1 }
  func count(_ url: URL) -> Int { counts[url, default: 0] }
  func total() -> Int { counts.values.reduce(0, +) }
}

@MainActor
final class TabFaviconCacheTests: XCTestCase {
  func testRequestsBeyondConcurrencyLimitWaitInsteadOfBeingDropped() async {
    let counts = FaviconRequestCounts()
    let cache = TabFaviconCache(fetch: { url in
      await counts.record(url)
      try? await Task.sleep(for: .milliseconds(20))
      return nil
    })
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<20 {
        group.addTask { _ = await cache.data(for: URL(string: "https://example.com/\(index)")!) }
      }
    }
    let total = await counts.total()
    XCTAssertEqual(total, 20)
  }

  func testSuccessfulReadRefreshesLRUAndEvictedIconIsFetchedAgain() async throws {
    let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
      bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let data = try XCTUnwrap(BrowserArtwork.encode(try XCTUnwrap(context.makeImage()), as: .favicon))
    let counts = FaviconRequestCounts()
    let cache = TabFaviconCache(countLimit: 2, fetch: { url in
      await counts.record(url)
      return data
    })
    let a = URL(string: "https://a.example/icon")!, b = URL(string: "https://b.example/icon")!
    let c = URL(string: "https://c.example/icon")!
    _ = await cache.data(for: a)
    _ = await cache.data(for: b)
    let hit = await cache.data(for: a)
    XCTAssertNotNil(hit)
    _ = await cache.data(for: c)
    _ = await cache.data(for: a)
    _ = await cache.data(for: b)
    let aCount = await counts.count(a), bCount = await counts.count(b)
    XCTAssertEqual(aCount, 1)
    XCTAssertEqual(bCount, 2)
  }

  func testMissingIconsExpireAndNegativeEntriesAlsoHaveAnLRULimit() async {
    let counts = FaviconRequestCounts()
    let cache = TabFaviconCache(countLimit: 2, fetch: { url in
      await counts.record(url)
      return nil
    })
    let a = URL(string: "https://a.example/icon")!, b = URL(string: "https://b.example/icon")!
    let c = URL(string: "https://c.example/icon")!
    _ = await cache.data(for: a, now: Date(timeIntervalSince1970: 0))
    _ = await cache.data(for: a, now: Date(timeIntervalSince1970: 299))
    let cachedCount = await counts.count(a)
    XCTAssertEqual(cachedCount, 1)
    _ = await cache.data(for: a, now: Date(timeIntervalSince1970: 301))
    _ = await cache.data(for: b, now: Date(timeIntervalSince1970: 302))
    _ = await cache.data(for: c, now: Date(timeIntervalSince1970: 303))
    _ = await cache.data(for: a, now: Date(timeIntervalSince1970: 304))
    let retriedCount = await counts.count(a)
    XCTAssertEqual(retriedCount, 3)
  }
}
