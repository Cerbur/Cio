import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Cached artwork has one bounded raster representation, not every native
/// image representation/frame. Legacy and network data are downsampled first.
public enum BrowserArtwork {
  public enum Kind: Sendable {
    case favicon, preview
    public var pixelLimit: Int { self == .favicon ? 64 : 320 }
    public var byteLimit: Int { 64 * 1024 }
  }

  public static func normalized(_ data: Data, as kind: Kind) -> Data? {
    guard data.count <= 1024 * 1024,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: kind.pixelLimit,
            kCGImageSourceCreateThumbnailWithTransform: true
          ] as CFDictionary) else { return nil }
    return encode(image, as: kind)
  }

  public static func encode(_ image: CGImage, as kind: Kind) -> Data? {
    let scale = min(1, Double(kind.pixelLimit) / Double(max(image.width, image.height)))
    let width = max(1, Int(Double(image.width) * scale))
    let height = max(1, Int(Double(image.height) * scale))
    guard let context = CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let raster = context.makeImage() else { return nil }
    let data = NSMutableData()
    let type = kind == .favicon ? UTType.png.identifier : UTType.jpeg.identifier
    guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, raster,
      [kCGImageDestinationLossyCompressionQuality: kind == .preview ? 0.6 : 1.0] as CFDictionary)
    guard CGImageDestinationFinalize(destination), data.length <= kind.byteLimit else { return nil }
    return data as Data
  }

  public static func decode(_ data: Data, as kind: Kind) -> CGImage? {
    guard data.count <= kind.byteLimit,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0, width <= kind.pixelLimit, height <= kind.pixelLimit else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }
}
