import AppKit

/// Checks the actual session's selected Chromium favicon before the tooling quit.
@MainActor
enum FaviconSelfTest {
  static func report(runtime: ApplicationRuntime) {
    guard let image = runtime.workspaceStore.selectedSession?.faviconImage,
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else {
      print("favicon-self-test: FAIL missing native favicon")
      return
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
    NSGraphicsContext.restoreGraphicsState()
    let visiblePixels = (0..<32).reduce(0) { count, x in
      count + (0..<32).filter { y in
        (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0
      }.count
    }
    let center = bitmap.colorAt(x: 16, y: 16)?.usingColorSpace(.deviceRGB)
    let styled = (center?.greenComponent ?? 0) > (center?.redComponent ?? 0)
    let passed = visiblePixels > 0 && styled
    print("favicon-self-test: \(passed ? "PASS" : "FAIL") visible-pixels=\(visiblePixels) svg-style=\(styled)")
  }
}
