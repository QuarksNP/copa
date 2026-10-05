import Foundation

/// The kind of thing that was copied. Every clip belongs to exactly one kind.
enum ClipKind: String, CaseIterable, Codable, Identifiable {
    case text
    case link
    case image
    case file
    case color

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "Text"
        case .link: "Links"
        case .image: "Images"
        case .file: "Files"
        case .color: "Colors"
        }
    }

    /// SF Symbol used for tabs and placeholders.
    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        }
    }

    /// One bit per kind, so a folder can remember everything it holds in a single number
    /// (`ClipFolder.kindsMask`) instead of being walked on every redraw.
    var bit: Int {
        switch self {
        case .text: 1 << 0
        case .link: 1 << 1
        case .image: 1 << 2
        case .file: 1 << 3
        case .color: 1 << 4
        }
    }
}

/// A tab in the notch: "All", one per kind, plus the sections the user made.
enum ClipCategory: Hashable, Identifiable {
    case all
    case kind(ClipKind)
    /// A section the user made, by its `ClipSection.id`.
    case section(UUID)

    /// The tabs Copa comes with. Custom sections follow them.
    static let builtIn: [ClipCategory] = [.all] + ClipKind.allCases.map { .kind($0) }

    var id: String {
        switch self {
        case .all: "all"
        case .kind(let kind): kind.rawValue
        case .section(let id): id.uuidString
        }
    }

    var title: String {
        switch self {
        case .all: "All"
        case .kind(let kind): kind.title
        // The tab bar draws sections from the section itself, which knows its name.
        case .section: "Section"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .kind(let kind): kind.symbol
        case .section: "folder"
        }
    }

    /// The custom section this tab shows, if it is one.
    var sectionID: UUID? {
        if case .section(let id) = self { return id }
        return nil
    }

    /// Does this tab show clips of that kind? Where the clip is filed is a separate question.
    func shows(_ item: ClipItem) -> Bool {
        switch self {
        case .all, .section: true
        case .kind(let kind): item.kind == kind
        }
    }

    /// A folder shows in a kind tab only when it holds something of that kind.
    func shows(_ folder: ClipFolder) -> Bool {
        switch self {
        case .all, .section: true
        case .kind(let kind): folder.holds(kind)
        }
    }
}
