import SwiftUI

/// "Move to" for a clip: the built-in history, every section, and every folder in them.
/// Folders are listed flat with their path ("Work › Scripts"), which stays readable however
/// deep they go, and keeps the menu one step away from every destination.
struct MoveToMenu: View {
    let item: ClipItem
    let sections: [ClipSection]
    let folders: [ClipFolder]
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu("Move to", systemImage: "folder") {
            Button("Copa History", systemImage: "clock") { move(toFolder: nil, section: nil) }
                .disabled(item.folderID == nil && item.sectionID == nil)
            destinations(in: nil)
            ForEach(sections) { section in
                Divider()
                Button(section.name, systemImage: section.symbol) { move(toFolder: nil, section: section.id) }
                    .disabled(item.folderID == nil && item.sectionID == section.id)
                destinations(in: section.id)
            }
        }
    }

    @ViewBuilder
    private func destinations(in sectionID: UUID?) -> some View {
        ForEach(FolderPath.sorted(folders, in: sectionID)) { folder in
            Button(FolderPath.label(for: folder, among: folders), systemImage: "folder") {
                move(toFolder: folder.id, section: sectionID)
            }
            .disabled(item.folderID == folder.id)
        }
    }

    private func move(toFolder folderID: UUID?, section sectionID: UUID?) {
        withAnimation(.snappy) { app.store.file(item, inFolder: folderID, section: sectionID) }
    }
}

/// "Move to" for a folder. A folder stays in its own section, so the destinations are the other
/// folders there — never itself or anything inside it.
struct MoveFolderMenu: View {
    let folder: ClipFolder
    let folders: [ClipFolder]
    @Environment(AppModel.self) private var app

    var body: some View {
        let family = ClipFolder.subtree(of: folder.id, in: folder.sectionID, among: folders)
        let elsewhere = FolderPath.sorted(folders, in: folder.sectionID).filter { !family.contains($0.id) }
        if !elsewhere.isEmpty || folder.parentID != nil {
            Menu("Move to", systemImage: "arrow.turn.up.right") {
                Button("Top Level", systemImage: "tray") {
                    withAnimation(.snappy) { app.store.move(folder, toParent: nil) }
                }
                .disabled(folder.parentID == nil)
                ForEach(elsewhere) { destination in
                    Button(FolderPath.label(for: destination, among: folders), systemImage: "folder") {
                        withAnimation(.snappy) { app.store.move(folder, toParent: destination.id) }
                    }
                    .disabled(folder.parentID == destination.id)
                }
            }
        }
    }
}

/// Writing a folder's place out as "Work › Scripts".
enum FolderPath {
    static func label(for folder: ClipFolder, among all: [ClipFolder]) -> String {
        var names = [folder.name]
        var current = folder.parentID
        for _ in 0..<ClipFolder.maxDepth {
            guard let id = current, let parent = all.first(where: { $0.id == id }) else { break }
            names.insert(parent.name, at: 0)
            current = parent.parentID
        }
        return names.joined(separator: " › ")
    }

    /// The folders of one section, in path order, so a menu reads like a list of places.
    static func sorted(_ all: [ClipFolder], in sectionID: UUID?) -> [ClipFolder] {
        all.filter { $0.sectionID == sectionID }
            .sorted { label(for: $0, among: all).localizedStandardCompare(label(for: $1, among: all)) == .orderedAscending }
    }
}
