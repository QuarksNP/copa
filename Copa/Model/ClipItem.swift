import Foundation
import SwiftData

/// One entry in the clipboard history, saved to disk with SwiftData.
@Model
final class ClipItem {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var createdAt: Date
    /// Updated every time the same content is copied again or reused from Copa.
    var lastUsedAt: Date
    var isPinned: Bool

    /// Text, link and color clips keep their original text here.
    var text: String?
    var urlString: String?
    var filePaths: [String]
    /// File names inside `BlobStore.directory`.
    var imageFilename: String?
    var thumbnailFilename: String?
    var imageWidth: Double
    var imageHeight: Double
    /// Normalized color, e.g. "#0A84FF" or "#0A84FF80".
    var colorHex: String?

    /// Link previews (title, page image and site icon), fetched after the link is copied.
    var linkTitle: String? = nil
    var linkImageFilename: String? = nil
    var linkIconFilename: String? = nil
    var linkPreviewFetched: Bool = false

    /// A name the user gave this clip in Copa (nil = use the automatic name).
    var customName: String? = nil

    /// Used to detect duplicates.
    var contentHash: String
    var sourceAppName: String?
    var sourceBundleID: String?

    init(kind: ClipKind, contentHash: String, sourceAppName: String?, sourceBundleID: String?) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.createdAt = .now
        self.lastUsedAt = .now
        self.isPinned = false
        self.filePaths = []
        self.imageWidth = 0
        self.imageHeight = 0
        self.contentHash = contentHash
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
    }

    var kind: ClipKind { ClipKind(rawValue: kindRaw) ?? .text }

    var url: URL? { urlString.flatMap(URL.init(string:)) }

    var fileURLs: [URL] { filePaths.map { URL(fileURLWithPath: $0) } }

    var imageURL: URL? { imageFilename.map(BlobStore.url(for:)) }

    var thumbnailURL: URL? { thumbnailFilename.map(BlobStore.url(for:)) }

    var linkImageURL: URL? { linkImageFilename.map(BlobStore.url(for:)) }

    var linkIconURL: URL? { linkIconFilename.map(BlobStore.url(for:)) }

    /// Every file this clip owns in `BlobStore`, so they can be removed together.
    var blobFilenames: [String?] { [imageFilename, thumbnailFilename, linkImageFilename, linkIconFilename] }

    /// The automatic name shown when the user hasn't renamed the clip.
    var defaultName: String {
        switch kind {
        case .text:
            let firstLine = (text ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return String(firstLine.trimmingCharacters(in: .whitespaces).prefix(60))
        case .link:
            if let linkTitle, !linkTitle.isEmpty { return linkTitle }
            return (url?.host() ?? "Link").replacingOccurrences(of: "www.", with: "")
        case .image:
            return "Image"
        case .file:
            return filePaths.first.map { ($0 as NSString).lastPathComponent } ?? "File"
        case .color:
            return colorHex ?? "Color"
        }
    }

    var displayName: String { customName ?? defaultName }

    /// Text used by the search field.
    var searchableText: String {
        [customName, text, urlString, linkTitle, filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: " "), sourceAppName]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}
