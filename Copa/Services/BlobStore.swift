import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Saves copied images as PNG files (plus a small thumbnail) in
/// ~/Library/Application Support/Copa/Images.
enum BlobStore {
    struct SavedImage: Sendable {
        let imageFilename: String
        let thumbnailFilename: String
        let width: Double
        let height: Double
    }

    nonisolated static let rootDirectory: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "Copa", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    nonisolated static let directory: URL = {
        let url = rootDirectory.appending(path: "Images", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    nonisolated static func url(for filename: String) -> URL {
        directory.appending(path: filename)
    }

    /// Formats stored as-is. Anything else (e.g. the uncompressed TIFF that apps put on the
    /// clipboard) is converted to PNG.
    nonisolated private static let keptFormats: [String: String] = [
        UTType.png.identifier: "png",
        UTType.jpeg.identifier: "jpg",
        UTType.heic.identifier: "heic",
        UTType.gif.identifier: "gif",
    ]

    /// Stores an image and a small thumbnail. Runs off the main thread.
    /// PNG/JPEG/HEIC/GIF are saved byte-for-byte (no decoding or re-encoding, which is slow for
    /// big screenshots); only the thumbnail is decoded, at reduced size.
    nonisolated static func saveImage(_ data: Data) -> SavedImage? {
        if isSVG(data) { return saveSVG(data) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double else { return nil }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }

        let id = UUID().uuidString
        let thumbName = "\(id)-thumb.png"
        let imageName: String
        if let type = CGImageSourceGetType(source) as String?, let ext = keptFormats[type] {
            imageName = "\(id).\(ext)"
            guard (try? data.write(to: url(for: imageName))) != nil else { return nil }
        } else {
            imageName = "\(id).png"
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  writePNG(image, to: url(for: imageName)) else { return nil }
        }
        guard writePNG(thumbnail, to: url(for: thumbName)) else { return nil }

        return SavedImage(imageFilename: imageName, thumbnailFilename: thumbName, width: width, height: height)
    }

    // MARK: SVG

    /// SVG is text, so look for an `<svg` tag near the start (after any XML header or comments).
    nonisolated static func isSVG(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(2048), encoding: .utf8) else { return false }
        return head.range(of: "<svg", options: .caseInsensitive) != nil
    }

    /// ImageIO can't read SVG, but NSImage can. The original vector file is kept as-is;
    /// only the thumbnail is rendered to PNG.
    nonisolated private static func saveSVG(_ data: Data) -> SavedImage? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
              let thumbnail = renderPNG(image, maxPixelSize: 480) else { return nil }
        let id = UUID().uuidString
        let imageName = "\(id).svg"
        let thumbName = "\(id)-thumb.png"
        guard (try? data.write(to: url(for: imageName))) != nil,
              (try? thumbnail.write(to: url(for: thumbName))) != nil else { return nil }
        return SavedImage(imageFilename: imageName, thumbnailFilename: thumbName,
                          width: image.size.width, height: image.size.height)
    }

    /// Draws an image (e.g. an SVG) into a PNG whose longest side is `maxPixelSize`.
    nonisolated static func renderPNG(_ image: NSImage, maxPixelSize: CGFloat) -> Data? {
        let scale = maxPixelSize / max(image.size.width, image.size.height)
        let width = max(Int(image.size.width * scale), 1)
        let height = max(Int(image.size.height * scale), 1)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Saves a downscaled PNG only (used for link preview images and site icons). Runs off the main thread.
    nonisolated static func saveThumbnail(_ data: Data, maxPixelSize: Int) -> String? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let name = "\(UUID().uuidString)-link.png"
        return writePNG(image, to: url(for: name)) ? name : nil
    }

    nonisolated private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    static func delete(_ filenames: [String?]) {
        for name in filenames.compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url(for: name))
            ImageCache.shared.remove(url(for: name))
        }
    }
}

/// Keeps decoded thumbnails and app icons in memory so scrolling stays smooth.
final class ImageCache {
    static let shared = ImageCache()
    private let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 150  // thumbnails are small; this keeps memory flat with long histories
        return cache
    }()
    private let fileIcons: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 100
        return cache
    }()

    /// Finder icon for a file; asking the system is slow, so each one is looked up once.
    func fileIcon(path: String) -> NSImage {
        if let icon = fileIcons.object(forKey: path as NSString) { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        fileIcons.setObject(icon, forKey: path as NSString)
        return icon
    }

    func image(at url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    func remove(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    private var appIcons: [String: NSImage] = [:]

    func appIcon(bundleID: String) -> NSImage? {
        if let icon = appIcons[bundleID] { return icon }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        appIcons[bundleID] = icon
        return icon
    }
}
