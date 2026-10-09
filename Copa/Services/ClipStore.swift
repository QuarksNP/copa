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
            container = try ModelContainer(for: ClipItem.self, ClipFolder.self, ClipSection.self,
                                           configurations: configuration)
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
        let (hash, isMarkdown) = await Task.detached { (payload.contentHash, payload.isMarkdown) }.value
        let sourceName = app?.localizedName ?? sourceName
        let sourceBundleID = app?.bundleIdentifier ?? sourceBundleID

        // Copied the same thing again? Move it to the front instead of storing a duplicate.
        if let existing = item(withHash: hash) {
            existing.lastUsedAt = .now
            if let sourceBundleID { existing.sourceAppName = sourceName; existing.sourceBundleID = sourceBundleID }
            existing.isMarkdown = isMarkdown
            save()
            onSave?(existing)
            return existing
        }

        let item = ClipItem(kind: payload.kind, contentHash: hash,
                            sourceAppName: sourceName, sourceBundleID: sourceBundleID)
        switch payload {
        case .text(let string):
            item.text = string
            item.isMarkdown = isMarkdown
        case .link(let url, let original):
            item.text = original
            item.urlString = url.absoluteString
        case .color(let string, let hex):
            item.text = string
            item.colorHex = hex
        case .files(let urls):
            item.filePaths = urls.map(\.path)
        case .image, .svgCode:
            let data: Data
            if case .svgCode(let code) = payload {
                data = Data(code.utf8)
                item.text = code  // remembered so it pastes back as code
            } else if case .image(let imageData) = payload {
                data = imageData
            } else { return nil }
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

    /// Text clips saved before Copa knew Markdown get looked at once, so their cards and pastes
    /// are formatted too. Reading happens off the main thread, a clip at a time.
    func detectMarkdownInOlderClips() async {
        let key = "markdownDetected"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let text = ClipKind.text.rawValue
        let descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.kindRaw == text })
        for item in (try? context.fetch(descriptor)) ?? [] {
            let sample = String((item.text ?? "").prefix(10_000))
            let isMarkdown = await Task.detached(priority: .utility) { Markdown.detect(sample) }.value
            if item.modelContext != nil, !item.isDeleted { item.isMarkdown = isMarkdown }
        }
        save()
        UserDefaults.standard.set(true, forKey: key)
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
        let folderID = item.folderID
        BlobStore.delete(item.blobFilenames)
        context.delete(item)
        save()
        refreshStats(from: folderID)
    }

    /// Deletes everything except pinned clips and the ones filed in a section or folder.
    func clearUnpinned() {
        let descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { !$0.isPinned && !$0.isFiled })
        for item in (try? context.fetch(descriptor)) ?? [] {
            BlobStore.delete(item.blobFilenames)
            context.delete(item)
        }
        save()
    }

    /// Removes the oldest clips beyond the history limit. Pinned clips and clips the user filed in
    /// a section or folder are kept: the limit only applies to the history that fills up by itself.
    func prune() {
        let limit = historyLimit
        guard limit > 0 else { return }
        var descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate { !$0.isPinned && !$0.isFiled },
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

    func save() {
        do { try context.save() } catch { print("Copa: failed to save – \(error)") }
    }
}
