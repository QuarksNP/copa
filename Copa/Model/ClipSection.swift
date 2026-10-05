import Foundation
import SwiftData

/// A tab the user made, shown in the notch next to All · Text · Links · Images · Files · Colors.
/// A section holds its own clips and folders; nothing in it appears in the built-in tabs.
@Model
final class ClipSection {
    @Attribute(.unique) var id: UUID
    var name: String
    /// SF Symbol shown on the tab.
    var symbol: String
    /// Tabs are shown in this order, after the built-in ones.
    var sortIndex: Int
    var createdAt: Date

    init(name: String, symbol: String = ClipSection.symbols[0], sortIndex: Int) {
        self.id = UUID()
        self.name = name
        self.symbol = symbol
        self.sortIndex = sortIndex
        self.createdAt = .now
    }

    /// Icons offered when making or editing a section.
    static let symbols = [
        "folder", "star", "briefcase", "chevron.left.forwardslash.chevron.right",
        "paintbrush", "book", "gamecontroller", "cart", "heart", "tag", "flag", "bolt",
    ]
}
