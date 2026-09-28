import AppKit
import SwiftUI

/// A borderless, transparent window that floats over the notch on every Space
/// and never steals focus from the app you're working in.
final class NotchPanel: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    // Allow typing in the search field without activating Copa.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Windows normally get pushed below the menu bar; we want to sit right on top of the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// Hosting view that reacts to the very first click, even though the panel isn't active.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The panel's root view. Tells Copa when the cursor enters or leaves the notch.
/// A tracking area costs nothing until the cursor crosses the notch, unlike watching
/// every mouse movement on the system.
final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private(set) var isHovered = false

    // Anchor content at the top, like the notch itself: if it's ever briefly the wrong size,
    // the notch shows the panel's black top edge rather than a slice from the bottom.
    override var isFlipped: Bool { true }

    // Keep the SwiftUI content exactly the size of the window, whenever the window changes.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        subviews.forEach { $0.frame = bounds }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .activeAlways: Copa never becomes the active app, but should still notice the cursor.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHoverChange?(false)
    }
}
