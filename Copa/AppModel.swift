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
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        PasteboardWriter.payloads(from: providers) { [store] payload in
            Task { _ = await store.add(payload, from: nil) }
        }
        return !providers.isEmpty
    }
}
