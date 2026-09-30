import AppKit

/// Watches the system clipboard and saves everything the user copies.
///
/// macOS doesn't announce clipboard changes, so we check the pasteboard's
/// `changeCount` twice per second — a very cheap operation.
@Observable
final class ClipboardMonitor {
    static let pausedKey = "capturePaused"

    private let store: ClipStore
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    @ObservationIgnored private var timer: Timer?
    /// Called when an image is copied (used to recognize screenshots copied to the clipboard).
    @ObservationIgnored var onImageCaptured: ((ClipItem) -> Void)?

    var isPaused: Bool = UserDefaults.standard.bool(forKey: ClipboardMonitor.pausedKey) {
        didSet { UserDefaults.standard.set(isPaused, forKey: Self.pausedKey) }
    }

    /// Whether macOS lets Copa read the clipboard in the background.
    var accessDenied: Bool { pasteboard.accessBehavior == .alwaysDeny }

    init(store: ClipStore) {
        self.store = store
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForChanges() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Call right after Copa itself writes to the clipboard so that write isn't recorded again.
    func ignoreCurrentChange() {
        lastChangeCount = pasteboard.changeCount
    }

    private func checkForChanges() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        let sourceApp = NSWorkspace.shared.frontmostApplication
        guard !isPaused,
              !ClipClassifier.shouldIgnore(pasteboard, from: sourceApp),
              let payload = ClipClassifier.payload(from: pasteboard) else { return }

        Task {
            if let item = await store.add(payload, from: sourceApp), item.kind == .image {
                onImageCaptured?(item)
            }
        }
    }
}
