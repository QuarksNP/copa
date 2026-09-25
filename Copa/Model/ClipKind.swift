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
}

/// A tab in the notch: "All" plus one tab per kind.
enum ClipCategory: Hashable, Identifiable, CaseIterable {
    case all
    case kind(ClipKind)

    static var allCases: [ClipCategory] { [.all] + ClipKind.allCases.map { .kind($0) } }

    var id: String {
        switch self {
        case .all: "all"
        case .kind(let kind): kind.rawValue
        }
    }

    var title: String {
        switch self {
        case .all: "All"
        case .kind(let kind): kind.title
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .kind(let kind): kind.symbol
        }
    }

    func contains(_ item: ClipItem) -> Bool {
        switch self {
        case .all: true
        case .kind(let kind): item.kind == kind
        }
    }
}
