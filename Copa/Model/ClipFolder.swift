import Foundation
import SwiftData

/// A folder of clips. Folders sit at the front of the carousel, like pinned clips, and open into
/// their own list. A folder can hold folders, as deep as you like.
///
/// Where a folder sits is kept as plain ids rather than SwiftData relationships: the carousel
/// filters every clip on each redraw, and reading an id costs nothing while following a
/// relationship would fault the whole object in.
@Model
final class ClipFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    /// One of `ClipFolder.palette`.
    var colorHex: String
    var createdAt: Date

    /// The section this folder lives in; nil means the built-in history (the All tab).
    /// A folder never changes section, so the clips inside it don't have to be updated either.
    var sectionID: UUID?
    /// The folder this one sits in; nil means the top level of its section.
    var parentID: UUID?

    /// Which kinds of clip are anywhere inside, one bit each (see `ClipKind.bit`). Kept up to date
    /// by `ClipStore`, so the Images tab can show the folders holding images without walking them.
    var kindsMask: Int
    /// How many clips and folders sit directly inside. Shown on the card.
    var itemCount: Int

    init(name: String, sectionID: UUID?, parentID: UUID?, colorHex: String) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.createdAt = .now
        self.sectionID = sectionID
        self.parentID = parentID
        self.kindsMask = 0
        self.itemCount = 0
    }

    /// True if a clip of this kind is anywhere inside.
    func holds(_ kind: ClipKind) -> Bool { kindsMask & kind.bit != 0 }

    /// The kinds inside, for the little symbols on the card.
    var kinds: [ClipKind] { ClipKind.allCases.filter(holds) }

    var isEmpty: Bool { itemCount == 0 }

    /// A color a folder can be given, with the name shown in its menu.
    struct Paint: Hashable, Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    /// Colors a folder can be given. New folders cycle through them.
    static let palette: [Paint] = [
        Paint(name: "Orange", hex: "#FF9F0A"),
        Paint(name: "Blue", hex: "#0A84FF"),
        Paint(name: "Red", hex: "#FF453A"),
        Paint(name: "Green", hex: "#30D158"),
        Paint(name: "Purple", hex: "#BF5AF2"),
        Paint(name: "Sky", hex: "#64D2FF"),
        Paint(name: "Yellow", hex: "#FFD60A"),
        Paint(name: "Pink", hex: "#FF6482"),
    ]

    /// How deep the walks below are willing to go. Folders nest as deep as the user likes; this
    /// only stops a loop if ids ever became inconsistent.
    static let maxDepth = 32

    /// Can the card being dragged be dropped into `folderID` (nil = the top level of `sectionID`)?
    /// A clip can go anywhere. A folder can't go inside itself, into a folder it contains, into
    /// another section, or back where it already is.
    static func canDrop(_ dragging: CarouselTarget?, into folderID: UUID?, section sectionID: UUID?,
                        among all: [ClipFolder]) -> Bool {
        guard case .folder(let id)? = dragging else { return true }
        guard id != folderID,
              let dragged = all.first(where: { $0.id == id }),
              dragged.sectionID == sectionID,
              dragged.parentID != folderID
        else { return false }
        guard let folderID else { return true }
        return !subtree(of: id, in: sectionID, among: all).contains(folderID)
    }

    /// `folderID` and every folder inside it, at any depth. Pass `nil` for a whole section,
    /// which gives every folder in it.
    static func subtree(of folderID: UUID?, in sectionID: UUID?, among all: [ClipFolder]) -> Set<UUID> {
        guard let folderID else { return Set(all.filter { $0.sectionID == sectionID }.map(\.id)) }
        var found: Set<UUID> = [folderID]
        var frontier: Set<UUID> = [folderID]
        for _ in 0..<maxDepth {
            let next = Set(all.filter { folder in
                guard let parent = folder.parentID else { return false }
                return frontier.contains(parent)
            }.map(\.id)).subtracting(found)
            if next.isEmpty { break }
            found.formUnion(next)
            frontier = next
        }
        return found
    }
}
