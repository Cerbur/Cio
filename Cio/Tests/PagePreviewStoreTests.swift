import CioEngine
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@MainActor
final class PagePreviewStoreTests: XCTestCase {
  private func directory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  private func image() throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8,
      bytesPerRow: 800 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
    return try XCTUnwrap(BrowserArtwork.encode(try XCTUnwrap(context.makeImage()), as: .preview))
  }

  func testNewStoreRestoresLastPreviewOnlyForTheSameTabAndURL() async throws {
    let root = try directory(), data = try image(), id = UUID()
    let url = URL(string: "https://example.com/a?q=1#section")!
    let original = PagePreviewStore(directory: root)
    await original.store(data, tabID: id, url: url)
    let relaunched = PagePreviewStore(directory: root)
    let restored = await relaunched.data(tabID: id, url: url)
    let changed = await relaunched.data(tabID: id, url: URL(string: "https://example.com/a?q=2#section"))
    XCTAssertEqual(restored, data)
    XCTAssertNil(changed)
    let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(PagePreviewStore.key(tabID: id, url: url)).path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testReadTouchSurvivesRelaunchAndProtectsEntryFromCountEviction() async throws {
    let root = try directory(), data = try image(), a = UUID(), b = UUID(), c = UUID()
    let url = URL(string: "https://example.com")!
    let original = PagePreviewStore(directory: root, limits: .init(count: 2))
    await original.store(data, tabID: a, url: url)
    await original.store(data, tabID: b, url: url)
    for (id, age) in [(a, 1.0), (b, 2.0)] {
      try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: age)],
        ofItemAtPath: root.appendingPathComponent(PagePreviewStore.key(tabID: id, url: url)).path)
    }
    let second = PagePreviewStore(directory: root, limits: .init(count: 2))
    _ = await second.data(tabID: a, url: url)
    let third = PagePreviewStore(directory: root, limits: .init(count: 2))
    await third.store(data, tabID: c, url: url)
    let kept = await third.data(tabID: a, url: url)
    let evicted = await third.data(tabID: b, url: url)
    XCTAssertEqual(kept, data)
    XCTAssertNil(evicted)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
  }

  func testByteBudgetCorruptionAndURLReplacementDoNotAccumulateFiles() async throws {
    let root = try directory(), data = try image(), a = UUID(), b = UUID()
    let url = URL(string: "https://example.com/a")!, next = URL(string: "https://example.com/b")!
    let store = PagePreviewStore(directory: root, limits: .init(count: 100, bytes: data.count * 2 - 1))
    await store.store(data, tabID: a, url: url)
    await store.store(data, tabID: b, url: url)
    let evicted = await store.data(tabID: a, url: url)
    XCTAssertNil(evicted)
    await store.store(data, tabID: b, url: next)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
    let path = root.appendingPathComponent(PagePreviewStore.key(tabID: b, url: next))
    try Data("broken".utf8).write(to: path)
    let restarted = PagePreviewStore(directory: root)
    let corrupt = await restarted.data(tabID: b, url: next)
    XCTAssertNil(corrupt)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
  }

  func testStartupPrunesClosedTabsAndEnforcesLoweredBudget() async throws {
    let root = try directory(), data = try image(), ids = (0..<4).map { _ in UUID() }
    let url = URL(string: "https://example.com")!
    let original = PagePreviewStore(directory: root)
    for id in ids { await original.store(data, tabID: id, url: url) }
    let smaller = PagePreviewStore(directory: root, limits: .init(count: 2))
    await smaller.retain(Dictionary(uniqueKeysWithValues: ids.map { ($0, url) }))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    await smaller.retain([:])
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  func testArtworkEncodingBoundsDecodedDimensionsAndRejectsInvalidData() throws {
    let data = try image()
    let preview = try XCTUnwrap(BrowserArtwork.decode(data, as: .preview))
    XCTAssertEqual(preview.width, 320)
    XCTAssertLessThanOrEqual(data.count, 64 * 1024)
    let iconData = try XCTUnwrap(BrowserArtwork.normalized(data, as: .favicon))
    let icon = try XCTUnwrap(BrowserArtwork.decode(iconData, as: .favicon))
    XCTAssertEqual(icon.width, 64)
    XCTAssertLessThanOrEqual(iconData.count, 64 * 1024)
    XCTAssertNil(BrowserArtwork.normalized(Data("broken".utf8), as: .favicon))
  }

  func testHighDetailPreviewsStayWithinTheSmallerBudgetAndLegacyCacheMigrates() async throws {
    let root = try directory(), id = UUID(), url = URL(string: "https://example.com")!
    // A detailed 512-pixel legacy JPEG exercises both pixel and byte migration;
    // solid-color fixtures would not catch overly optimistic JPEG size budgets.
    var state: UInt32 = 12345
    var pixels = [UInt8](repeating: 255, count: 512 * 512 * 4)
    for index in pixels.indices where index % 4 != 3 {
      state = state &* 1664525 &+ 1013904223
      pixels[index] = UInt8(truncatingIfNeeded: state >> 24)
    }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
    let raster = try XCTUnwrap(CGImage(width: 512, height: 512, bitsPerComponent: 8,
      bitsPerPixel: 32, bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let compact = try XCTUnwrap(BrowserArtwork.encode(raster, as: .preview))
    XCTAssertLessThanOrEqual(compact.count, 64 * 1024)
    XCTAssertEqual(BrowserArtwork.decode(compact, as: .preview)?.width, 320)
    let legacy = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(legacy, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, raster, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    XCTAssertGreaterThan(legacy.length, 64 * 1024)
    let path = root.appendingPathComponent(PagePreviewStore.key(tabID: id, url: url))
    try (legacy as Data).write(to: path)
    let store = PagePreviewStore(directory: root)
    let restored = await store.data(tabID: id, url: url)
    let migrated = try XCTUnwrap(restored)
    XCTAssertLessThanOrEqual(migrated.count, 64 * 1024)
    XCTAssertEqual(BrowserArtwork.decode(migrated, as: .preview)?.width, 320)
    let diskSize = try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber
    XCTAssertLessThanOrEqual(try XCTUnwrap(diskSize).intValue, 64 * 1024)
    let smallLegacy = NSMutableData()
    let smallDestination = try XCTUnwrap(CGImageDestinationCreateWithData(smallLegacy, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(smallDestination, raster, [kCGImageDestinationLossyCompressionQuality: 0.1] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(smallDestination))
    XCTAssertLessThanOrEqual(smallLegacy.length, 64 * 1024)
    let second = UUID()
    try (smallLegacy as Data).write(to: root.appendingPathComponent(PagePreviewStore.key(tabID: second, url: url)))
    let relaunched = PagePreviewStore(directory: root)
    let secondRestored = await relaunched.data(tabID: second, url: url)
    let secondImage = try XCTUnwrap(secondRestored)
    XCTAssertEqual(BrowserArtwork.decode(secondImage, as: .preview)?.width, 320)
  }

  func testDisabledStorageAndRejectedWritesLeaveNoExtraFiles() async throws {
    let root = try directory(), data = try image(), id = UUID()
    let url = URL(string: "https://example.com")!
    let zero = PagePreviewStore(directory: root, limits: .init(count: 0))
    await zero.store(data, tabID: id, url: url)
    let disabled = PagePreviewStore(directory: nil)
    await disabled.store(data, tabID: id, url: url)
    let absent = await disabled.data(tabID: id, url: url)
    XCTAssertNil(absent)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    let store = PagePreviewStore(directory: root)
    await store.store(data, tabID: id, url: url)
    await store.store(Data(repeating: 0, count: 1024 * 1024), tabID: id, url: url)
    let kept = await store.data(tabID: id, url: url)
    XCTAssertEqual(kept, data)
    await store.invalidate(tabID: id)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }
}
