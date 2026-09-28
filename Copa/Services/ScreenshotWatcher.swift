import AppKit
import SwiftData
import UniformTypeIdentifiers

/// Saves new screenshots (⇧⌘3, ⇧⌘4, ⇧⌘5) into Copa, even though macOS saves them as files
/// instead of copying them. Uses Spotlight, which tags every screenshot with
/// `kMDItemIsScreenCapture`, so it works wherever the user's screenshots are saved.
///
/// macOS only writes the file once its floating thumbnail disappears (~5 s later), so the
/// watcher also spots the moment each screenshot is taken, to show "saving…" feedback right away.
///
/// Cases handled:
/// - One screenshot, or several in a row (each one is counted).
/// - ⇧⌘5 toolbar opened and cancelled (nothing is counted until something is captured).
/// - Screen recordings (not treated as a pending screenshot; the video is saved to Files).
/// - Thumbnail dragged into an app or deleted (the feedback ends after a few seconds).
/// - Screenshots copied to the clipboard instead of saved (resolved when the image arrives there).
/// - Any save folder and any display.
@Observable
final class ScreenshotWatcher {
    static let enabledKey = "saveScreenshots"
    private static let screenshotAppID = "com.apple.screencaptureui"

    enum Event {
        /// A screenshot was just taken; macOS hasn't saved the file yet.
        case started
        /// The screenshot is now in Copa.
        case saved(ClipItem)
        /// The screenshot was dragged away or deleted from its thumbnail, so nothing is coming.
        case abandoned
    }

    @ObservationIgnored var onEvent: ((Event) -> Void)?
    /// Screenshots taken but not saved to disk yet.
    private(set) var pendingCount = 0

    @ObservationIgnored private var captureTimer: Timer?
    /// Capture indicators seen, with when they appeared. Recordings keep theirs on screen.
    @ObservationIgnored private var indicatorsSeenAt: [Int: Date] = [:]
    @ObservationIgnored private var recordingIndicators: Set<Int> = []
    @ObservationIgnored private var lastToolSeen = Date.distantPast
    @ObservationIgnored private var lastCaptureSignal = Date.distantPast

    private let store: ClipStore
    private let monitor: ClipboardMonitor
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Screenshots already saved, so repeated Spotlight updates don't add them twice.
    @ObservationIgnored private var handledPaths: Set<String> = []

    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.isEnabled) {
                UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            }
            newValue ? start() : stop()
        }
    }

    init(store: ClipStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
    }

    func start() {
        guard isEnabled, query == nil else { return }
        requestFolderAccess()

        let query = NSMetadataQuery()
        // Only screenshots taken from now on; older ones are left alone.
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate >= %@", Date.now as NSDate)
        query.searchScopes = [NSMetadataQueryUserHomeScope]

        let center = NotificationCenter.default
        // Screenshots found by the first search (taken while it was still running)…
        observers.append(center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            let items = query.results.compactMap { $0 as? NSMetadataItem }
            let paths = items.compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
            MainActor.assumeIsolated { self?.save(paths) }
        })
        // …and every screenshot taken after that.
        observers.append(center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] note in
            let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
            let paths = added.compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
            MainActor.assumeIsolated { self?.save(paths) }
        })

        query.start()
        self.query = query

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForNewCapture() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        captureTimer = timer
    }

    func stop() {
        captureTimer?.invalidate()
        captureTimer = nil
        pendingCount = 0
        indicatorsSeenAt.removeAll()
        recordingIndicators.removeAll()
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Where macOS saves screenshots: Desktop, unless changed in the ⇧⌘5 Options menu.
    static var screenshotFolder: URL {
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        return custom.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL.desktopDirectory
    }

    /// Desktop, Documents and Downloads are protected by macOS. Spotlight silently hides files there
    /// from apps without access, so look inside the folder once: that makes macOS ask the user.
    private func requestFolderAccess() {
        _ = try? FileManager.default.contentsOfDirectory(atPath: Self.screenshotFolder.path)
    }

    private func save(_ paths: [String]) {
        guard !monitor.isPaused else { return }
        for path in paths where !handledPaths.contains(path) {
            handledPaths.insert(path)
            let url = URL(fileURLWithPath: path)
            let type = UTType(filenameExtension: url.pathExtension)
            Task {
                let payload: ClipPayload
                if type?.conforms(to: .image) == true {
                    guard let data = await Task.detached(operation: { try? Data(contentsOf: url) }).value else { return }
                    payload = .image(data)
                } else if type?.conforms(to: .movie) == true {
                    // Screen recordings can be huge: keep a reference to the file instead of a copy.
                    payload = .files([url])
                } else {
                    return
                }
                guard let item = await store.add(payload, from: nil,
                                                 sourceName: "Screenshot", sourceBundleID: "com.apple.screenshot.launcher")
                else { return }
                resolve(with: item)
            }
        }
    }

    /// A screenshot copied to the clipboard (⌃⇧⌘4, or "Save to Clipboard") never becomes a file.
    /// Called when an image arrives on the clipboard: if a screenshot was just taken, that's it.
    func clipboardImageArrived(_ item: ClipItem) {
        guard isEnabled, pendingCount > 0 else { return }
        resolve(with: item)
    }

    private func resolve(with item: ClipItem) {
        pendingCount = max(pendingCount - 1, 0)
        onEvent?(.saved(item))
    }

    #if DEBUG
    /// Pretends a screenshot was taken / saved / abandoned (for testing the notch feedback).
    func debugSimulate(_ step: String) {
        switch step {
        case "start":
            lastToolSeen = .now
            pendingCount += 1
            onEvent?(.started)
        case "abandon":
            pendingCount = 0
            onEvent?(.abandoned)
        default:
            var newestImage = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.kindRaw == "image" },
                                                        sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
            newestImage.fetchLimit = 1
            guard let item = try? store.context.fetch(newestImage).first else { return }
            pendingCount = max(pendingCount - 1, 0)
            onEvent?(.saved(item))
        }
    }
    #endif

    // MARK: Instant feedback

    /// macOS flashes a tiny capture indicator in the menu bar for every screenshot, about 0.2 s
    /// before the screenshot tool (screencaptureui) starts, and keeps it for ~3 s. A new indicator
    /// means "a screenshot was just taken". The tool stays open ~11 s after each screenshot.
    ///
    /// Checked four times a second. The window list is only read while the tool is running,
    /// so when you're not taking screenshots this costs almost nothing.
    private func checkForNewCapture() {
        guard !monitor.isPaused else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.screenshotAppID).isEmpty == false else {
            indicatorsSeenAt.removeAll()
            recordingIndicators.removeAll()
            giveUpIfNothingArrived()
            return
        }
        lastToolSeen = .now

        let indicators = Self.captureIndicators()
        for number in indicators where indicatorsSeenAt[number] == nil {
            indicatorsSeenAt[number] = .now
            registerCapture()
        }
        // An indicator that stays up is a screen recording, not a screenshot: stop waiting for it.
        // (The video is saved to Files when the recording ends.)
        for number in indicators where !recordingIndicators.contains(number) {
            guard let seenAt = indicatorsSeenAt[number], Date.now.timeIntervalSince(seenAt) > 5 else { continue }
            recordingIndicators.insert(number)
            pendingCount = max(pendingCount - 1, 0)
            if pendingCount == 0 { onEvent?(.abandoned) }
        }
        indicatorsSeenAt = indicatorsSeenAt.filter { indicators.contains($0.key) || Date.now.timeIntervalSince($0.value) < 30 }
    }

    private func registerCapture() {
        pendingCount += 1
        lastCaptureSignal = .now
        // The save folder may have changed since launch (⇧⌘5 › Options); make sure Copa can read it.
        requestFolderAccess()
        onEvent?(.started)
    }

    /// The capture indicator: a very high-level system window, about 10×19 points,
    /// in the menu bar of any display.
    private static func captureIndicators() -> Set<Int> {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        // Top edge of each display, in window-list coordinates (origin at the top-left of the main display).
        let menuBars = NSScreen.screens.map { screen in
            CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY, width: screen.frame.width, height: 40)
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(windows.compactMap { window -> Int? in
            guard let layer = window[kCGWindowLayer as String] as? Int, layer >= 2_000_000_000,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width <= 40, rect.height <= 40,
                  menuBars.contains(where: { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) })
            else { return nil }
            return window[kCGWindowNumber as String] as? Int
        })
    }

    /// A few seconds passed with no file: the screenshot was dragged into another app or deleted
    /// from its thumbnail, so nothing is coming.
    private func giveUpIfNothingArrived() {
        guard pendingCount > 0, Date.now.timeIntervalSince(max(lastToolSeen, lastCaptureSignal)) > 3 else { return }
        pendingCount = 0
        onEvent?(.abandoned)
    }
}
