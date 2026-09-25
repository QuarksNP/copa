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

    /// Decodes any image format and writes a full-size PNG and a thumbnail. Runs off the main thread.
    nonisolated static func saveImage(_ data: Data) -> SavedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
        ]
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) ?? image

        let id = UUID().uuidString
        let imageName = "\(id).png"
        let thumbName = "\(id)-thumb.png"
        guard writePNG(image, to: url(for: imageName)), writePNG(thumbnail, to: url(for: thumbName)) else { return nil }

        return SavedImage(imageFilename: imageName, thumbnailFilename: thumbName,
                          width: Double(image.width), height: Double(image.height))
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
    private let cache = NSCache<NSURL, NSImage>()

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
