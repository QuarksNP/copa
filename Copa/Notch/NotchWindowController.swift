import AppKit
import SwiftData
import SwiftUI

/// Owns the notch window: finds the notch, detects hovering, and expands/collapses the panel.
///
/// Trick: while collapsed, the window is exactly the size of the notch (dead space in the
/// menu bar, so it never blocks anything). When expanding, the window grows instantly to
/// full size and SwiftUI animates the black shape open inside it.
@Observable
final class NotchController {
    // MARK: Layout constants

    static let expandedSize = CGSize(width: 760, height: 276)
    static let collapsedTopRadius: CGFloat = 6
    static let collapsedBottomRadius: CGFloat = 10
    static let expandedTopRadius: CGFloat = 14
    static let expandedBottomRadius: CGFloat = 28
    /// Extra transparent room around the expanded shape so its shadow isn't clipped.
    static let shadowPadding: CGFloat = 30

    static let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let closeAnimation = Animation.spring(response: 0.35, dampingFraction: 0.9)

    // MARK: State read by the SwiftUI views

    private(set) var isExpanded = false
    private(set) var notchSize = CGSize(width: 185, height: 32)
    private(set) var hasNotch = true
    // Changing the tab, search or pin filter puts the selection back on the first card.
    var category: ClipCategory = .all { didSet { selectedItemID = nil } }
    var searchText = "" { didSet { selectedItemID = nil } }
    var showPinnedOnly = false { didSet { selectedItemID = nil } }

    /// Cards currently shown in the carousel, in order (kept up to date by the view).
    var visibleItemIDs: [UUID] = []
    /// The card chosen with the arrow keys. nil means "the first card".
    var selectedItemID: UUID?

    /// The card that Delete / Return act on: the chosen one, or the first (the latest copy).
    var selection: UUID? {
        if let selectedItemID, visibleItemIDs.contains(selectedItemID) { return selectedItemID }
        return visibleItemIDs.first
    }

    /// True while something is being dragged over the notch.
    var isDropTargeted = false {
        didSet { if isDropTargeted && !isExpanded { expand() } }
    }

    /// True while a card is being dragged out of Copa, so the notch doesn't treat it as a drop.
    var isDraggingFromCard = false

    /// The clip whose name is being edited, if any.
    var editingItemID: UUID?

    var collapsedShapeSize: CGSize {
        CGSize(width: notchSize.width + 2 * Self.collapsedTopRadius, height: notchSize.height)
    }

    // MARK: Private

    @ObservationIgnored private let panel = NotchPanel()
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
        let container = NSView()
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        panel.contentView = container
        hostingView.frame = container.bounds
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if self.editingItemID != nil { self.editingItemID = nil } else { self.collapse() }
        }

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
        panel.setFrame(isExpanded ? expandedFrame : collapsedFrame, display: true)
    }

    private var collapsedFrame: CGRect {
        guard let screen else { return .zero }
        let size = collapsedShapeSize
        return CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
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

    private var hoverRect: CGRect {
        // A little padding on the sides, and up past the top edge so slamming the cursor into the top works.
        collapsedFrame.insetBy(dx: -6, dy: 0).union(collapsedFrame.offsetBy(dx: 0, dy: 4))
    }

    // MARK: Expand / collapse

    func expand(fromMenu: Bool = false) {
        hoverWorkItem?.cancel()
        outsideSince = nil
        guard !isExpanded else { return }
        openedFromMenu = fromMenu
        mouseHasEntered = false
        editingItemID = nil
        selectedItemID = nil
        panel.setFrame(expandedFrame, display: true)
        panel.orderFrontRegardless()
        // Take keyboard focus (without switching apps) so the arrow keys, Delete and Return work.
        panel.makeKey()
        withAnimation(Self.openAnimation) { isExpanded = true }
        startTracking()
    }

    func collapse() {
        guard isExpanded else { return }
        stopTracking()
        searchText = ""
        app.panelDidClose()
        if panel.isKeyWindow {
            // Hand keyboard focus back to the app the user was working in.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        withAnimation(Self.closeAnimation) {
            isExpanded = false
        } completion: { [weak self] in
            guard let self, !self.isExpanded else { return }
            self.panel.setFrame(self.collapsedFrame, display: true)
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
    private func handleKey(_ event: NSEvent) -> Bool {
        guard isExpanded, event.window === panel,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              // Let the search and rename fields handle their own typing.
              !(panel.firstResponder is NSText) else { return false }

        switch Int(event.keyCode) {
        case 123: moveSelection(by: -1)                  // ←
        case 124: moveSelection(by: 1)                   // →
        case 51, 117: deleteSelection()                   // Delete, Forward Delete
        case 36, 76: copySelectionAndClose()              // Return, Enter
        default: return false
        }
        return true
    }

    private func moveSelection(by offset: Int) {
        guard let current = selection, let index = visibleItemIDs.firstIndex(of: current) else { return }
        let newIndex = min(max(index + offset, 0), visibleItemIDs.count - 1)
        withAnimation(.snappy(duration: 0.25)) { selectedItemID = visibleItemIDs[newIndex] }
    }

    private func deleteSelection() {
        guard let current = selection, let index = visibleItemIDs.firstIndex(of: current),
              let item = clip(withID: current) else { return }
        // Select the card that slides into its place (or the one before, if it was the last).
        let neighbors = visibleItemIDs.indices.contains(index + 1) ? index + 1 : index - 1
        withAnimation(.snappy) {
            selectedItemID = visibleItemIDs.indices.contains(neighbors) ? visibleItemIDs[neighbors] : nil
            app.store.delete(item)
        }
    }

    private func copySelectionAndClose() {
        guard let current = selection, let item = clip(withID: current) else { return }
        app.copy(item)
        collapse()
    }

    private func clip(withID id: UUID) -> ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? app.store.context.fetch(descriptor).first
    }

    private func installMonitors() {
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            (self?.handleKey(event) ?? false) ? nil : event
        }) { monitors.append(keys) }

        // Hovering the notch while collapsed. Mouse-moved monitors need no special permission.
        let moveEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moveEvents, handler: { [weak self] _ in
            self?.mouseMoved()
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moveEvents, handler: { [weak self] event in
            self?.mouseMoved()
            return event
        }) { monitors.append(local) }

        // Clicking anywhere else closes the panel.
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self, self.isExpanded, !self.expandedShapeRect.contains(NSEvent.mouseLocation) else { return }
            self.collapse()
        }) { monitors.append(clicks) }

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
        // Switches tab, e.g. object: "link".
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.copa.debug.category"), object: nil, queue: .main) { [weak self] note in
            let raw = note.object as? String
            MainActor.assumeIsolated {
                self?.category = raw.flatMap(ClipKind.init(rawValue:)).map { .kind($0) } ?? .all
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
                if name.isEmpty { self.editingItemID = item.id } else { self.app.store.rename(item, to: name) }
            }
        })
        // Simulates a key press (object: key code, e.g. "124" for →) through the real key handler.
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

    private func mouseMoved() {
        guard !isExpanded else { return }
        guard hoverRect.contains(NSEvent.mouseLocation) else {
            hoverWorkItem?.cancel()
            hoverWorkItem = nil
            return
        }
        guard hoverWorkItem == nil else { return }
        // Wait a moment so the panel doesn't pop open when the cursor just passes by.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWorkItem = nil
            if self.hoverRect.contains(NSEvent.mouseLocation) { self.expand() }
        }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Called by the collapsed notch view when the cursor enters it.
    func hoverChanged(_ hovering: Bool) {
        if hovering { mouseMoved() }
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
        if !buttonDown && isDraggingFromCard { isDraggingFromCard = false }

        if inside {
            mouseHasEntered = true
            outsideSince = nil
            return
        }
        // Keep open while dragging, while a menu is open, while renaming, or right after opening from the menu bar.
        if buttonDown || isMenuOpen || isDropTargeted || editingItemID != nil || (openedFromMenu && !mouseHasEntered) {
            outsideSince = nil
            return
        }
        let since = outsideSince ?? .now
        outsideSince = since
        if Date.now.timeIntervalSince(since) > 0.3 { collapse() }
    }
}
