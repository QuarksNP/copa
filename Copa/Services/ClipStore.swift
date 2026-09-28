import AppKit
import SwiftData

/// Saves, de-duplicates and trims the clipboard history.
@Observable
final class ClipStore {
    static let historyLimitKey = "historyLimit"
    static let defaultHistoryLimit = 500

    let container: ModelContainer
    /// Called after a clip is saved or moved to the front (used to fetch link previews).
    @ObservationIgnored var onSave: ((ClipItem) -> Void)?
    var context: ModelContext { container.mainContext }

    /// Maximum number of unpinned clips to keep. 0 means unlimited.
    var historyLimit: Int {
        get {
            access(keyPath: \.historyLimit)
            return UserDefaults.standard.object(forKey: Self.historyLimitKey) as? Int ?? Self.defaultHistoryLimit
        }
        set {
            withMutation(keyPath: \.historyLimit) {
                UserDefaults.standard.set(newValue, forKey: Self.historyLimitKey)
            }
            prune()
        }
    }

    init() {
        // Store the database in our own folder (non-sandboxed apps would otherwise share "default.store").
        let storeURL = BlobStore.rootDirectory.appending(path: "Copa.store")
        let configuration = ModelConfiguration(url: storeURL)
        do {
            container = try ModelContainer(for: ClipItem.self, configurations: configuration)
        } catch {
            fatalError("Could not open Copa's database: \(error)")
        }
    }

    // MARK: Adding

    /// Saves a clip. The source is shown on the card: pass the app it came from,
    /// or a name and bundle ID directly (e.g. for screenshots).
    @discardableResult
    func add(_ payload: ClipPayload, from app: NSRunningApplication?,
             sourceName: String? = nil, sourceBundleID: String? = nil) async -> ClipItem? {
        let hash = await Task.detached { payload.contentHash }.value
        let sourceName = app?.localizedName ?? sourceName
        let sourceBundleID = app?.bundleIdentifier ?? sourceBundleID

        // Copied the same thing again? Move it to the front instead of storing a duplicate.
        if let existing = item(withHash: hash) {
            existing.lastUsedAt = .now
            if let sourceBundleID { existing.sourceAppName = sourceName; existing.sourceBundleID = sourceBundleID }
            save()
            onSave?(existing)
            return existing
        }

        let item = ClipItem(kind: payload.kind, contentHash: hash,
                            sourceAppName: sourceName, sourceBundleID: sourceBundleID)
        switch payload {
        case .text(let string):
            item.text = string
        case .link(let url, let original):
            item.text = original
            item.urlString = url.absoluteString
        case .color(let string, let hex):
            item.text = string
            item.colorHex = hex
        case .files(let urls):
            item.filePaths = urls.map(\.path)
        case .image(let data):
            // Encoding big screenshots takes a moment, so do it in the background.
            guard let saved = await Task.detached(operation: { BlobStore.saveImage(data) }).value else { return nil }
            // Another copy of the same image may have finished first.
            if let existing = self.item(withHash: hash) {
                BlobStore.delete([saved.imageFilename, saved.thumbnailFilename])
                return existing
            }
            item.imageFilename = saved.imageFilename
            item.thumbnailFilename = saved.thumbnailFilename
            item.imageWidth = saved.width
            item.imageHeight = saved.height
        }

        context.insert(item)
        save()
        prune()
        onSave?(item)
        return item
    }

    private func item(withHash hash: String) -> ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.contentHash == hash })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: Editing

    func markUsed(_ item: ClipItem) {
        item.lastUsedAt = .now
        save()
    }

    /// Gives a clip a custom name. An empty name (or the automatic one) removes the custom name.
    func rename(_ item: ClipItem, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        item.customName = (trimmed.isEmpty || trimmed == item.defaultName) ? nil : trimmed
        save()
    }

    func togglePin(_ item: ClipItem) {
        item.isPinned.toggle()
        save()
        prune()
    }

    func delete(_ item: ClipItem) {
        BlobStore.delete(item.blobFilenames)
        context.delete(item)
        save()
    }

    /// Deletes everything except pinned clips.
    func clearUnpinned() {
        let descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { !$0.isPinned })
        for item in (try? context.fetch(descriptor)) ?? [] {
            BlobStore.delete(item.blobFilenames)
            context.delete(item)
        }
        save()
    }

    /// Removes the oldest unpinned clips beyond the history limit.
    func prune() {
        let limit = historyLimit
        guard limit > 0 else { return }
        var descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate { !$0.isPinned },
            sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
        )
        descriptor.fetchOffset = limit
        let overflow = (try? context.fetch(descriptor)) ?? []
        guard !overflow.isEmpty else { return }
        for item in overflow {
            BlobStore.delete(item.blobFilenames)
            context.delete(item)
        }
        save()
    }

    private func save() {
        do { try context.save() } catch { print("Copa: failed to save – \(error)") }
    }
}
