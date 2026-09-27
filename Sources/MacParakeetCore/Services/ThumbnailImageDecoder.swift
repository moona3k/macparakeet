import CoreGraphics
import Foundation
import ImageIO

/// Decodes cached thumbnail files at display size.
///
/// Cached artwork is usually 1280x720 or larger, while Library cards draw it
/// at a few hundred points. Decoding through ImageIO's thumbnail path keeps
/// the bitmap small and does the work eagerly, so callers can decode off the
/// main thread and hand the finished image to the UI.
public enum ThumbnailImageDecoder {
    /// Returns the image at `url` scaled so its longest side is at most
    /// `maxPixelSize`, honoring EXIF orientation. Returns `nil` when the file
    /// is missing or is not a decodable image.
    public static func image(contentsOf url: URL, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let thumbnailOptions =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }
}
