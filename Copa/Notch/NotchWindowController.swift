import AppKit
import SwiftData
import SwiftUI

/// One card in the carousel: a folder, or a clip. What the arrow keys move between.
enum CarouselTarget: Hashable {
    case folder(UUID)
    case clip(UUID)

    /// The id the carousel scrolls to. Folder and clip ids never collide.
    var scrollID: UUID {
        switch self {
        case .folder(let id), .clip(let id): id
        }
    }
}

/// Owns the notch window: finds the notch, detects hovering, and expands/collapses the panel.
///
/// Trick: while collapsed, the window is exactly the size of the notch (dead space in the
/// menu bar, so it never blocks anything). When expanding, the window grows instantly to
/// full size and SwiftUI animates the black shape open inside it.
@Observable
final class NotchController {
    // MARK: Layout constants

    static let expandedSize = CGSize(width: 820, height: 312)
    static let collapsedTopRadius: CGFloat = 6
    static let collapsedBottomRadius: CGFloat = 10
    static let expandedTopRadius: CGFloat = 14
    static let expandedBottomRadius: CGFloat = 28
    /// Extra transparent room around the expanded shape so its shadow isn't clipped.
    static let shadowPadding: CGFloat = 30
    /// How far the notch grows on each side to show an activity (like a screenshot being saved).
    static let activityWing: CGFloat = 40

    static let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let closeAnimation = Animation.spring(response: 0.35, dampingFraction: 0.9)

    // MARK: State read by the SwiftUI views

    private(set) var isExpanded = false
    private(set) var notchSize = CGSize(width: 185, height: 32)
    private(set) var hasNotch = true
    // Changing the tab, search or pin filter puts the selection back on the first card.
    // Switching tabs also leaves whatever folder was open: it belongs to the tab you left.
    var category: ClipCategory = .all {
        didSet {
            guard category != oldValue else { return }
            folderPath = []
            selectedEntry = nil
        }
    }
    var searchText = "" { didSet { selectedEntry = nil } }
    var showPinnedOnly = false { didSet { selectedEntry = nil } }

    /// The folders we're looking inside, outermost first. Empty means the top level of the tab.
    /// Folders are kept as ids, not objects: the one we're in can be deleted from under us.
    private(set) var folderPath: [UUID] = []

    /// The folder whose contents the carousel is showing, if any.
    var currentFolderID: UUID? { folderPath.last }

    /// Everything the carousel is showing, in order (kept up to date by the view).
    var visibleEntries: [CarouselTarget] = []
    /// The card chosen with the arrow keys. nil means "the first card".
    var selectedEntry: CarouselTarget?

    /// The card that Delete / Return act on: the chosen one, or the first (the latest copy).
    var selection: CarouselTarget? {
        if let selectedEntry, visibleEntries.contains(selectedEntry) { return selectedEntry }
        return visibleEntries.first
    }

    /// Changes whenever the carousel should start again from the first card.
    var locationID: String {
        category.id + folderPath.map(\.uuidString).joined() + String(showPinnedOnly)
    }

    /// True while something is being dragged over the notch.
    var isDropTargeted = false {
        didSet { if isDropTargeted && !isExpanded { expand() } }
    }

    /// True while a card is being dragged out of Copa, so the notch doesn't treat it as a drop.
    var isDraggingFromCard = false

    /// The card being dragged right now: a clip, so dropping it on a folder files it instead of
    /// saving a second copy of what it holds, or a folder, so dropping it moves the folder.
    var dragging: CarouselTarget?

    /// Called by whatever took the drop, and when the mouse button comes back up.
    func endDrag() {
        dragging = nil
        isDraggingFromCard = false
    }

    /// What's being renamed inline, if anything.
    enum Editing: Hashable {
        case clip(UUID)
        case folder(UUID)
        case section(UUID)
    }

    var editing: Editing?

    var collapsedShapeSize: CGSize {
        CGSize(width: notchSize.width + 2 * Self.collapsedTopRadius, height: notchSize.height)
    }

    /// Something shown in the collapsed notch, Dynamic Island style.
    enum Activity: Equatable {
        case savingScreenshot
        /// `symbol` is shown when there's no thumbnail (e.g. a screen recording).
        case savedScreenshot(thumbnail: URL?, symbol: String)
    }

    private(set) var activity: Activity? { didSet { updateHoverArea() } }

    var activityShapeSize: CGSize {
        CGSize(width: collapsedShapeSize.width + 2 * Self.activityWing, height: notchSize.height)
    }

    // MARK: Private

    @ObservationIgnored private let panel = NotchPanel()
    @ObservationIgnored private let hoverView = HoverTrackingView()
    /// The SwiftUI content inside `hoverView`.
    @ObservationIgnored private var contentView: NSView!
    /// Watches for clicks outside Copa; only installed while the panel is open.
    @ObservationIgnored private var clickMonitor: Any?
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var screen: NSScreen?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var hoverWorkItem: DispatchWorkItem?
    @ObservationIgnored private var trackingTimer: Timer?
    @ObservationIgnored private var outsideSince: Date?
    @ObservationIgnored private var openedFromMenu = false
    @ObservationIgnored private var mouseHasEntered = false
    @ObservationIgnored private var isMenuOpen = false
    #if DEBUG
    /// Debug builds only: keeps the panel open while it's driven from Terminal.
    @ObservationIgnored private var isHeldOpen = false
    #endif
    @ObservationIgnored private var activityEndWork: DispatchWorkItem?
    /// Longest the "saving" spinner stays up, e.g. while the user annotates the screenshot in Markup.
    private static let maxSpinnerTime: TimeInterval = 15
    /// How long the cursor must stay outside the open panel before it closes. Short, so what's under
    /// the panel (like the menu bar) is usable right after leaving; long enough to forgive overshooting an edge.
    private static let closeDelay: TimeInterval = 0.1

    init(app: AppModel) {
        self.app = app
        let root = NotchView()
            .environment(self)
            .environment(app)
            .modelContainer(app.store.container)
            .preferredColorScheme(.dark)
            .tint(.accentColor)
        let hostingView = NotchHostingView(rootView: root)
        // The window sits over the notch/menu bar; don't let safe areas or content size move it around.
        hostingView.sizingOptions = []
        hostingView.safeAreaRegions = []
        // Wrapping the SwiftUI view in a plain container keeps it from fighting AppKit over the window size.
        // The container also tells us when the cursor enters the notch.
        hostingView.autoresizingMask = [.width, .height]
        hoverView.addSubview(hostingView)
        panel.contentView = hoverView
        hostingView.frame = hoverView.bounds
        contentView = hostingView
        hoverView.onHoverChange = { [weak self] hovering in self?.hoverChanged(hovering) }
        // Esc backs out one step at a time: stop renaming, leave the folder, then close.
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if self.editing != nil {
                self.editing = nil
            } else if !self.folderPath.isEmpty {
                self.goUp()
            } else {
                self.collapse()
            }
        }

        app.screenshots.onEvent = { [weak self] event in self?.handleScreenshot(event) }

        layout()
        panel.orderFrontRegardless()
        installMonitors()
    }

    // MARK: Geometry

    /// Finds the screen with a notch (or falls back to the main screen) and sizes the window.
    func layout() {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        let screen = notched ?? NSScreen.main ?? NSScreen.screens.first
        self.screen = screen
        guard let screen else { return }

        if let notched, let left = notched.auxiliaryTopLeftArea, let right = notched.auxiliaryTopRightArea {
            hasNotch = true
            notchSize = CGSize(width: right.minX - left.maxX, height: notched.safeAreaInsets.top)
        } else {
            // No notch: use an invisible hot zone the size of the menu bar at the top center.
            hasNotch = false
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            notchSize = CGSize(width: 200, height: max(menuBarHeight, 24))
        }
        setPanelFrame(isExpanded ? expandedFrame : restingFrame)
    }

    /// Resizes the notch window and makes sure its content follows right away. Relying on automatic
    /// resizing alone could leave the open panel's content inside the small closed notch (a slice of
    /// cards showing in the notch) when the resize happened mid-animation.
    private func setPanelFrame(_ frame: CGRect) {
        panel.setFrame(frame, display: false)
        contentView.frame = hoverView.bounds
        contentView.needsLayout = true
        contentView.layoutSubtreeIfNeeded()
        // AppKit refreshes tracking areas only some time after a resize; do it now.
        updateHoverArea()
        hoverView.needsDisplay = true
        panel.displayIfNeeded()
    }

    /// Only the closed notch (wider during an activity) counts as hovering, even while the window is
    /// panel-sized. Otherwise, heading for the menu bar under a closing panel would open it again.
    private func updateHoverArea() {
        hoverView.hoverSize = activity == nil ? collapsedShapeSize : activityShapeSize
        hoverView.updateTrackingAreas()
    }

    private var collapsedFrame: CGRect {
        guard let screen else { return .zero }
        let size = collapsedShapeSize
        return CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private var activityFrame: CGRect {
        guard let screen else { return .zero }
        let size = activityShapeSize
        return CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// The window size while not expanded: just the notch, or a bit wider during an activity.
    private var restingFrame: CGRect {
        activity == nil ? collapsedFrame : activityFrame
    }

    private var expandedFrame: CGRect {
        guard let screen else { return .zero }
        let width = Self.expandedSize.width + 2 * Self.shadowPadding
        let height = Self.expandedSize.height + Self.shadowPadding
        return CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    /// The visible black area when expanded, in screen coordinates.
    private var expandedShapeRect: CGRect {
        guard let screen else { return .zero }
        let size = Self.expandedSize
        return CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: Expand / collapse

    func expand(fromMenu: Bool = false) {
        hoverWorkItem?.cancel()
        outsideSince = nil
        guard !isExpanded else { return }
        openedFromMenu = fromMenu
        mouseHasEntered = false
        editing = nil
        selectedEntry = nil
        setPanelFrame(expandedFrame)
        panel.orderFrontRegardless()
        // Take keyboard focus (without switching apps) so the arrow keys, Delete and Return work.
        panel.makeKey()
        withAnimation(Self.openAnimation) { isExpanded = true }
        startTracking()
        // Clicking anywhere else closes the panel.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isExpanded, !self.expandedShapeRect.contains(NSEvent.mouseLocation) else { return }
            self.collapse()
        }
    }

    func collapse() {
        guard isExpanded else { return }
        stopTracking()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if panel.isKeyWindow {
            // Hand keyboard focus back to the app the user was working in.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        withAnimation(Self.closeAnimation) {
            isExpanded = false
        } completion: { [weak self] in
            self?.shrinkIfClosed()
        }
        // Safety net: if the animation's completion is ever skipped, don't leave an invisible
        // panel-sized window over the screen blocking clicks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.shrinkIfClosed() }
    }

    private func shrinkIfClosed() {
        guard !isExpanded else { return }
        resetAfterClosing()
        guard panel.frame != restingFrame else { return }
        setPanelFrame(restingFrame)
    }

    /// Clears the search and moves reused clips to the front, only once the panel is fully closed.
    /// Doing it while the close animation runs made the carousel scroll mid-animation, which left
    /// the open panel's content stuck inside the closed notch.
    private func resetAfterClosing() {
        if !searchText.isEmpty { searchText = "" }
        if !folderPath.isEmpty { folderPath = [] }
        selectedEntry = nil
        editing = nil
        app.panelDidClose()
    }

    // MARK: Folders

    /// Shows what's inside a folder. The carousel keeps working exactly as it does at the top level.
    func open(folderID: UUID) {
        guard folderPath.last != folderID else { return }
        withAnimation(.snappy(duration: 0.3)) {
            folderPath.append(folderID)
            selectedEntry = nil
        }
    }

    /// Goes back to the folder around this one.
    func goUp() {
        guard !folderPath.isEmpty else { return }
        withAnimation(.snappy(duration: 0.3)) {
            folderPath.removeLast()
            selectedEntry = nil
        }
    }

    /// Jumps to a step in the path shown above the carousel; 0 is the tab itself.
    func go(toDepth depth: Int) {
        guard depth < folderPath.count else { return }
        withAnimation(.snappy(duration: 0.3)) {
            folderPath = Array(folderPath.prefix(depth))
            selectedEntry = nil
        }
    }

    /// Drops steps that point at folders which no longer exist (the view watches for this).
    func trimPath(toExisting ids: Set<UUID>) {
        guard let first = folderPath.firstIndex(where: { !ids.contains($0) }) else { return }
        withAnimation(.snappy(duration: 0.3)) {
            folderPath = Array(folderPath.prefix(first))
            selectedEntry = nil
        }
    }

    // MARK: Activities

    private func handleScreenshot(_ event: ScreenshotWatcher.Event) {
        switch event {
        case .started:
            show(.savingScreenshot)
        case .saved(let item):
            show(.savedScreenshot(thumbnail: item.thumbnailURL, symbol: item.kind == .file ? "video.fill" : "photo"))
            // Show the result briefly, then shrink back (or keep spinning if another one is on its way).
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.app.screenshots.pendingCount > 0 { self.show(.savingScreenshot) } else { self.endActivity() }
            }
            activityEndWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
        case .abandoned:
            endActivity()
        }
    }

    private func show(_ newActivity: Activity) {
        activityEndWork?.cancel()
        // Grow the window first; SwiftUI then animates the notch widening inside it.
        if !isExpanded { setPanelFrame(activityFrame) }
        withAnimation(Self.openAnimation) { activity = newActivity }

        if newActivity == .savingScreenshot {
            // Don't spin forever: the screenshot still shows up (with a checkmark) whenever it's saved.
            let work = DispatchWorkItem { [weak self] in self?.endActivity() }
            activityEndWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxSpinnerTime, execute: work)
        }
    }

    private func endActivity() {
        activityEndWork?.cancel()
        guard activity != nil else { return }
        withAnimation(Self.closeAnimation) {
            activity = nil
        } completion: { [weak self] in
            guard let self, !self.isExpanded, self.activity == nil else { return }
            self.setPanelFrame(self.collapsedFrame)
        }
    }

    /// Lets the panel receive typing (for renaming) without switching away from the current app.
    func focusPanel() {
        panel.makeKey()
    }

    func toggle() {
        isExpanded ? collapse() : expand(fromMenu: true)
    }

    // MARK: Mouse tracking

    // MARK: Keyboard

    /// ← → move between cards, Delete removes the selected card, Return copies it and closes.
    /// On a folder, Return opens it and Delete removes it when it's empty.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard isExpanded, event.window === panel,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              // Let the search and rename fields handle their own typing.
              !(panel.firstResponder is NSText) else { return false }

        switch Int(event.keyCode) {
        case 123: moveSelection(by: -1)                  // ←
        case 124: moveSelection(by: 1)                   // →
        case 51, 117: deleteSelection()                   // Delete, Forward Delete
        case 36, 76: useSelection()                       // Return, Enter
        default: return false
        }
        return true
    }

    private func moveSelection(by offset: Int) {
        guard let current = selection, let index = visibleEntries.firstIndex(of: current) else { return }
        let newIndex = min(max(index + offset, 0), visibleEntries.count - 1)
        withAnimation(.snappy(duration: 0.25)) { selectedEntry = visibleEntries[newIndex] }
    }

    /// Delete removes the selected clip. A folder goes only when it's empty: throwing away
    /// everything inside with one keystroke can't be taken back, so a folder with contents is
    /// deleted from its menu, where both outcomes are spelled out.
    private func deleteSelection() {
        guard let current = selection, let index = visibleEntries.firstIndex(of: current) else { return }
        // Select the card that slides into its place (or the one before, if it was the last).
        let neighbor = visibleEntries.indices.contains(index + 1) ? index + 1 : index - 1
        let next = visibleEntries.indices.contains(neighbor) ? visibleEntries[neighbor] : nil

        switch current {
        case .clip(let id):
            guard let item = clip(withID: id) else { return }
            withAnimation(.snappy) {
                selectedEntry = next
                app.store.delete(item)
            }
        case .folder(let id):
            guard let folder = folder(withID: id), folder.isEmpty else { return }
            withAnimation(.snappy) {
                selectedEntry = next
                app.store.delete(folder, keepingContents: false)
            }
        }
    }

    /// Return copies the selected clip and closes Copa. On a folder it opens the folder instead.
    private func useSelection() {
        switch selection {
        case .clip(let id):
            guard let item = clip(withID: id) else { return }
            app.copy(item)
            collapse()
        case .folder(let id):
            open(folderID: id)
        case nil:
            break
        }
    }

    private func clip(withID id: UUID) -> ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? app.store.context.fetch(descriptor).first
    }

    private func folder(withID id: UUID) -> ClipFolder? {
        var descriptor = FetchDescriptor<ClipFolder>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? app.store.context.fetch(descriptor).first
    }

    private func installMonitors() {
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            (self?.handleKey(event) ?? false) ? nil : event
        }) { monitors.append(keys) }


        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        })
        #if DEBUG
        // Lets you open/close the notch from Terminal while developing:
        // swift -e 'import Foundation; DistributedNotificationCenter.default().post(name: .init("com.copa.debug.toggle"), object: nil)'
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug.toggle"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
        })
        // Holds the panel open (object: "off" to let it close again), for driving it from Terminal.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug.hold"), object: nil, queue: .main) { [weak self] note in
            let off = (note.object as? String) == "off"
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isHeldOpen = !off
                if self.isHeldOpen { self.expand(fromMenu: true) }
            }
        })
        // Switches tab: a kind ("link"), a section's name, or anything else for All.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug.category"), object: nil, queue: .main) { [weak self] note in
            let raw = note.object as? String ?? ""
            MainActor.assumeIsolated {
                guard let self else { return }
                if let kind = ClipKind(rawValue: raw) {
                    self.category = .kind(kind)
                } else if let section = self.app.store.sections().first(where: { $0.name == raw }) {
                    self.category = .section(section.id)
                } else {
                    self.category = .all
                }
            }
        })
        // Types in the search field (object: the text; empty clears it).
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug.search"), object: nil, queue: .main) { [weak self] note in
            let text = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.searchText = text }
        })
        // Makes a folder where we are (object: its name), or a section (com.copa.debug.newsection).
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug.newfolder"), object: nil, queue: .main) { [weak self] note in
            let name = note.object as? String ?? "New Folder"
            MainActor.assumeIsolated {
                guard let self else { return }
                _ = self.app.store.addFolder(name: name, in: self.category.sectionID, parentID: self.currentFolderID)
            }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug.newsection"), object: nil, queue: .main) { [weak self] note in
            let name = note.object as? String ?? "New Section"
            MainActor.assumeIsolated { _ = self?.app.store.addSection(name: name) }
        })
        // Does what dropping a card on a folder (or on a step of the path) does, so drag and drop
        // can be exercised without a mouse. Object: "SOURCE>DEST", where SOURCE is a folder's name
        // or "selection" for the chosen card, and DEST is a folder's name or empty for the top
        // level. Writes whether the drop was allowed to copa-drop.txt in the temporary folder.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug.drop"), object: nil, queue: .main) { [weak self] note in
            let parts = (note.object as? String ?? "").components(separatedBy: ">")
            MainActor.assumeIsolated {
                guard let self, parts.count == 2 else { return }
                let all = self.app.store.folders()
                let sectionID = self.category.sectionID
                let destination = all.first { $0.name == parts[1] && $0.sectionID == sectionID }?.id
                let dragging: CarouselTarget? = parts[0] == "selection"
                    ? self.selection
                    : all.first { $0.name == parts[0] }.map { .folder($0.id) }
                var outcome = "drop \(parts[0])>\(parts[1])"
                if parts[0] != "selection" && dragging == nil {
                    outcome += " no-source"
                } else if !parts[1].isEmpty && destination == nil {
                    outcome += " no-destination"
                } else if !ClipFolder.canDrop(dragging, into: destination, section: sectionID, among: all) {
                    outcome += " refused"
                } else {
                    let took = self.app.acceptDrop([], dragging: dragging, inFolder: destination, section: sectionID)
                    outcome += took ? " accepted" : " failed"
                }
                self.dragging = nil
                try? outcome.write(to: FileManager.default.temporaryDirectory.appending(path: "copa-drop.txt"),
                                   atomically: true, encoding: .utf8)
            }
        })
        // Removes a section by name, keeping its clips (…all deletes them with it).
        for (suffix, keep) in [("delsection", true), ("delsectionall", false)] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug." + suffix), object: nil, queue: .main) { [weak self] note in
                let name = note.object as? String ?? ""
                MainActor.assumeIsolated {
                    guard let self, let section = self.app.store.sections().first(where: { $0.name == name }) else { return }
                    if self.category == .section(section.id) { self.category = .all }
                    self.app.store.delete(section, keepingContents: keep)
                }
            })
        }
        // Deletes a folder here by name, keeping what's inside (…all moves it out with the folder).
        for (suffix, keep) in [("delfolder", true), ("delfolderall", false)] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug." + suffix), object: nil, queue: .main) { [weak self] note in
                let name = note.object as? String ?? ""
                MainActor.assumeIsolated {
                    guard let self, let folder = self.app.store.folders().first(where: {
                        $0.name == name && $0.sectionID == self.category.sectionID && $0.parentID == self.currentFolderID
                    }) else { return }
                    self.app.store.delete(folder, keepingContents: keep)
                }
            })
        }
        // Opens a folder here by name, ".." to go back, or "" for the top level.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug.openfolder"), object: nil, queue: .main) { [weak self] note in
            let name = note.object as? String ?? ""
            MainActor.assumeIsolated {
                guard let self else { return }
                if name == ".." { self.goUp(); return }
                if name.isEmpty { self.go(toDepth: 0); return }
                let match = self.app.store.folders().first {
                    $0.name == name && $0.sectionID == self.category.sectionID && $0.parentID == self.currentFolderID
                }
                if let match { self.open(folderID: match.id) }
            }
        })
        // Files the selected clip into a folder here by name, or "" to take it back out.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug.file"), object: nil, queue: .main) { [weak self] note in
            let name = note.object as? String ?? ""
            MainActor.assumeIsolated {
                guard let self, case .clip(let id)? = self.selection, let item = self.clip(withID: id) else { return }
                guard !name.isEmpty else { return self.app.store.file(item, inFolder: nil, section: nil) }
                if let section = self.app.store.sections().first(where: { $0.name == name }) {
                    return self.app.store.file(item, inFolder: nil, section: section.id)
                }
                let match = self.app.store.folders().first {
                    $0.name == name && $0.sectionID == self.category.sectionID && $0.parentID == self.currentFolderID
                }
                if let match { self.app.store.file(item, inFolder: match.id, section: match.sectionID) }
            }
        })
        // Renames the newest clip (object: new name), or opens the rename field when the name is empty.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug.rename"), object: nil, queue: .main) { [weak self] note in
            let name = note.object as? String ?? ""
            MainActor.assumeIsolated {
                guard let self else { return }
                var newest = FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
                newest.fetchLimit = 1
                guard let item = try? self.app.store.context.fetch(newest).first else { return }
                if name.isEmpty { self.editing = .clip(item.id) } else { self.app.store.rename(item, to: name) }
            }
        })
        // Simulates a key press (object: key code, e.g. "124" for →) through the real key handler.
        // Writes the window's view tree (class, frame, hidden) to the temporary folder.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug.views"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var lines = ["window \(self.panel.frame) expanded=\(self.isExpanded)"]
                lines.append("tab=\(self.category.id) path=\(self.folderPath.count) selection=\(String(describing: self.selection)) entries=\(self.visibleEntries.count)")
                for folder in self.app.store.folders() {
                    lines.append("folder \(folder.name) section=\(folder.sectionID?.uuidString.prefix(4) ?? "-") parent=\(folder.parentID?.uuidString.prefix(4) ?? "-") items=\(folder.itemCount) kinds=\(folder.kinds.map(\.rawValue).joined(separator: ","))")
                }
                for section in self.app.store.sections() {
                    lines.append("section \(section.name) id=\(section.id.uuidString.prefix(4)) symbol=\(section.symbol)")
                }
                func walk(_ view: NSView, _ depth: Int) {
                    guard depth < 14 else { return }
                    lines.append(String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame) hidden=\(view.isHidden) alpha=\(view.alphaValue)")
                    view.subviews.forEach { walk($0, depth + 1) }
                }
                walk(self.hoverView, 0)
                try? lines.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appending(path: "copa-views.txt"), atomically: true, encoding: .utf8)
            }
        })
        // Copies the selected card like a click does (without closing the panel).
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug.copy"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .clip(let id)? = self.selection,
                      let item = self.clip(withID: id) else { return }
                self.app.copy(item)
            }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug.key"), object: nil, queue: .main) { [weak self] note in
            let code = UInt16(note.object as? String ?? "") ?? 0
            MainActor.assumeIsolated {
                guard let self, let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: self.panel.windowNumber, context: nil, characters: "",
                    charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else { return }
                _ = self.handleKey(event)
            }
        })
        // Simulates a screenshot (object: "start", "saved" or "abandon").
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug.screenshot"), object: nil, queue: .main) { [weak self] note in
            let step = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.app.screenshots.debugSimulate(step) }
        })
        // Saves a picture of the notch window to the temporary folder (for checking the design).
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug.snapshot"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let view = self?.panel.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: FileManager.default.temporaryDirectory.appending(path: "copa-snapshot.png"))
            }
        })
        #endif
        // Don't collapse while a context menu from a card is open.
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isMenuOpen = true }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isMenuOpen = false }
        })
    }

    /// The cursor entered or left the notch.
    private func hoverChanged(_ hovering: Bool) {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        guard hovering, !isExpanded else { return }
        // Wait a moment so the panel doesn't pop open when the cursor just passes by.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWorkItem = nil
            if self.hoverView.isHovered { self.expand() }
        }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// While expanded, poll the cursor so we can close once it leaves — this also works
    /// during drag and drop, when normal mouse events aren't delivered.
    private func startTracking() {
        trackingTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        outsideSince = nil
    }

    private func trackMouse() {
        let inside = expandedShapeRect.insetBy(dx: -10, dy: -10).contains(NSEvent.mouseLocation)
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        if !buttonDown && isDraggingFromCard { endDrag() }

        if inside {
            mouseHasEntered = true
            outsideSince = nil
            return
        }
        #if DEBUG
        if isHeldOpen { outsideSince = nil; return }
        #endif
        // Keep open while dragging, while a menu is open, while renaming, or right after opening from the menu bar.
        if buttonDown || isMenuOpen || isDropTargeted || editing != nil || (openedFromMenu && !mouseHasEntered) {
            outsideSince = nil
            return
        }
        let since = outsideSince ?? .now
        outsideSince = since
        if Date.now.timeIntervalSince(since) >= Self.closeDelay { collapse() }
    }
}
