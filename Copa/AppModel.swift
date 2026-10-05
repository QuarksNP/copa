import AppKit
import SwiftData

/// The app's shared state, handed to every view through the SwiftUI environment.
@Observable
final class AppModel {
    let store = ClipStore()
    let monitor: ClipboardMonitor
    let linkPreviews = LinkPreviewLoader()
    let screenshots: ScreenshotWatcher

    init() {
        monitor = ClipboardMonitor(store: store)
        screenshots = ScreenshotWatcher(store: store, monitor: monitor)
        monitor.onImageCaptured = { [screenshots] item in screenshots.clipboardImageArrived(item) }
        store.onSave = { [linkPreviews] item in linkPreviews.loadIfNeeded(item) }
    }

    /// Clips reused while the panel is open. They move to the front once it closes,
    /// so cards don't jump around under the cursor.
    private var recentlyUsed: [ClipItem] = []

    /// Puts a clip back on the clipboard so the user can paste it with ⌘V.
    func copy(_ item: ClipItem) {
        PasteboardWriter.copy(item)
        monitor.ignoreCurrentChange()
        recentlyUsed.removeAll { $0.id == item.id }
        recentlyUsed.append(item)
    }

    func panelDidClose() {
        for item in recentlyUsed where item.modelContext != nil {
            store.markUsed(item)
        }
        recentlyUsed.removeAll()
    }

    /// Saves whatever was dropped on the notch; it's sorted into the right category automatically.
    /// Dropping on a folder (or while a section is open) files it there instead of the history.
    func handleDrop(_ providers: [NSItemProvider], inFolder folderID: UUID? = nil, section sectionID: UUID? = nil) -> Bool {
        PasteboardWriter.payloads(from: providers) { [store] payload in
            Task {
                guard let item = await store.add(payload, from: nil) else { return }
                if folderID != nil || sectionID != nil {
                    store.file(item, inFolder: folderID, section: sectionID)
                }
            }
        }
        return !providers.isEmpty
    }

    /// Takes a card dropped on a folder, or on a step of the path above the carousel: a clip is
    /// filed there and a folder moves there. Anything dragged in from another app is saved there
    /// instead. Check `ClipFolder.canDrop` first; this trusts the destination.
    @discardableResult
    func acceptDrop(_ providers: [NSItemProvider], dragging: CarouselTarget?,
                    inFolder folderID: UUID?, section sectionID: UUID?) -> Bool {
        switch dragging {
        case .clip(let id):
            guard let item = clip(withID: id) else { return false }
            store.file(item, inFolder: folderID, section: sectionID)
            return true
        case .folder(let id):
            guard let folder = store.folders().first(where: { $0.id == id }) else { return false }
            store.move(folder, toParent: folderID)
            return true
        case nil:
            return handleDrop(providers, inFolder: folderID, section: sectionID)
        }
    }

    /// Looks a clip up by id, for the places that only carry the id (dragging, the keyboard).
    func clip(withID id: UUID) -> ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? store.context.fetch(descriptor).first
    }
}
