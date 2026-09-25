import LinkPresentation
import SwiftData
import UniformTypeIdentifiers

/// Fetches a page's title, preview image and site icon with Apple's LinkPresentation
/// framework (the same previews you see in Messages and Notes).
@Observable
final class LinkPreviewLoader {
    static let enabledKey = "linkPreviewsEnabled"

    /// Links currently being fetched, so cards can show a spinner.
    private(set) var loadingIDs: Set<UUID> = []

    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.isEnabled) {
                UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            }
        }
    }

    func isLoading(_ item: ClipItem) -> Bool { loadingIDs.contains(item.id) }

    /// Fetches the preview once per link. Safe to call repeatedly.
    func loadIfNeeded(_ item: ClipItem) {
        guard isEnabled, item.kind == .link, !item.linkPreviewFetched,
              !loadingIDs.contains(item.id), let url = item.url else { return }
        loadingIDs.insert(item.id)

        Task {
            defer { loadingIDs.remove(item.id) }

            let provider = LPMetadataProvider()
            provider.timeout = 12
            guard let metadata = try? await provider.startFetchingMetadata(for: url) else {
                // Offline or the site didn't answer; try again next time the card appears.
                return
            }

            async let imageData = Self.imageData(from: metadata.imageProvider)
            async let iconData = Self.imageData(from: metadata.iconProvider)
            let (image, icon) = await (imageData, iconData)

            let imageName: String? = if let image {
                await Task.detached { BlobStore.saveThumbnail(image, maxPixelSize: 480) }.value
            } else { nil }
            let iconName: String? = if let icon {
                await Task.detached { BlobStore.saveThumbnail(icon, maxPixelSize: 64) }.value
            } else { nil }

            // The clip may have been deleted while we were loading.
            guard item.modelContext != nil else {
                BlobStore.delete([imageName, iconName])
                return
            }
            BlobStore.delete([item.linkImageFilename, item.linkIconFilename])
            item.linkTitle = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            item.linkImageFilename = imageName
            item.linkIconFilename = iconName
            item.linkPreviewFetched = true
            try? item.modelContext?.save()
        }
    }

    private static func imageData(from provider: NSItemProvider?) async -> Data? {
        guard let provider,
              let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true })
        else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
