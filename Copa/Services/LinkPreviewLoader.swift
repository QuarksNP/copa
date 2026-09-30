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
    /// Links that `LinkPreviewPolicy` rules out are never visited; their card shows the address only.
    func loadIfNeeded(_ item: ClipItem) {
        guard isEnabled, item.kind == .link, !item.linkPreviewFetched,
              !loadingIDs.contains(item.id), let url = item.url else { return }
        guard LinkPreviewPolicy.allowsPreview(of: url) else {
            skipPreview(for: item)
            return
        }
        loadingIDs.insert(item.id)

        Task {
            defer { loadingIDs.remove(item.id) }

            // Public names can still point to this Mac or the local network.
            switch await LinkPreviewPolicy.resolvesToPublicAddresses(url) {
            case true?: break
            case false?: skipPreview(for: item); return
            case nil: return  // Offline; try again next time the card appears.
            }

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

    /// Remembers that this link gets no preview, so it isn't checked again.
    private func skipPreview(for item: ClipItem) {
        guard item.modelContext != nil else { return }
        item.linkPreviewFetched = true
        try? item.modelContext?.save()
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
