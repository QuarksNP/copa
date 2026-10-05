import Foundation
import SwiftData

/// Sections and folders: making them, and moving clips around in them.
///
/// Folders remember what they hold (`kindsMask`, `itemCount`) so the carousel never has to walk
/// them while drawing. Everything here keeps those two numbers correct, and everything here runs
/// on a deliberate action by the user, never while Copa is idle.
extension ClipStore {

    // MARK: Reading

    /// Every section, in tab order.
    func sections() -> [ClipSection] {
        let descriptor = FetchDescriptor<ClipSection>(
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Every folder, oldest first, so folders keep their place as new ones appear.
    func folders() -> [ClipFolder] {
        let descriptor = FetchDescriptor<ClipFolder>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    private func allClips() -> [ClipItem] {
        (try? context.fetch(FetchDescriptor<ClipItem>())) ?? []
    }

    // MARK: Sections

    @discardableResult
    func addSection(name: String) -> ClipSection {
        let existing = sections()
        let section = ClipSection(name: name,
                                  symbol: ClipSection.symbols[existing.count % ClipSection.symbols.count],
                                  sortIndex: (existing.last?.sortIndex ?? -1) + 1)
        context.insert(section)
        save()
        return section
    }

    func rename(_ section: ClipSection, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        section.name = trimmed
        save()
    }

    func setSymbol(_ section: ClipSection, to symbol: String) {
        section.symbol = symbol
        save()
    }

    /// Moves a tab one place left (-1) or right (1).
    func move(_ section: ClipSection, by offset: Int) {
        let all = sections()
        guard let index = all.firstIndex(where: { $0.id == section.id }) else { return }
        let target = index + offset
        guard all.indices.contains(target) else { return }
        // Rewrite every index, in case older sections share one.
        var reordered = all
        reordered.swapAt(index, target)
        for (position, item) in reordered.enumerated() { item.sortIndex = position }
        save()
    }

    /// Removes a section. What's in it is either deleted with it, or moved back to the built-in
    /// history keeping its folders.
    func delete(_ section: ClipSection, keepingContents: Bool) {
        let id = section.id
        let inSection = folders().filter { $0.sectionID == id }
        let clips = allClips().filter { $0.sectionID == id }

        if keepingContents {
            for folder in inSection { folder.sectionID = nil }
            for clip in clips { setLocation(clip, folder: clip.folderID, section: nil) }
        } else {
            for clip in clips { destroy(clip) }
            for folder in inSection { context.delete(folder) }
        }
        context.delete(section)
        save()
        refreshAllStats()
    }

    // MARK: Folders

    @discardableResult
    func addFolder(name: String, in sectionID: UUID?, parentID: UUID?) -> ClipFolder {
        let all = folders()
        // A folder always lives in the same section as the folder around it.
        let sectionID = parentID.flatMap { id in all.first { $0.id == id }?.sectionID } ?? sectionID
        let folder = ClipFolder(name: name, sectionID: sectionID, parentID: parentID,
                                colorHex: ClipFolder.palette[all.count % ClipFolder.palette.count].hex)
        context.insert(folder)
        save()
        refreshStats(from: parentID)
        return folder
    }

    func rename(_ folder: ClipFolder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folder.name = trimmed
        save()
    }

    func setColor(_ folder: ClipFolder, to hex: String) {
        folder.colorHex = hex
        save()
    }

    /// Moves a folder into another one, or back to the top level of its own section.
    func move(_ folder: ClipFolder, toParent parentID: UUID?) {
        guard parentID != folder.id else { return }
        let all = folders()
        if let parentID {
            // A folder can't go inside itself, and it never changes section — otherwise every
            // clip below it would have to be rewritten too.
            guard let parent = all.first(where: { $0.id == parentID }),
                  parent.sectionID == folder.sectionID,
                  !ClipFolder.subtree(of: folder.id, in: folder.sectionID, among: all).contains(parentID)
            else { return }
        }
        let oldParent = folder.parentID
        folder.parentID = parentID
        save()
        refreshStats(from: oldParent)
        refreshStats(from: parentID)
    }

    /// Deletes a folder. `keepingContents` moves what's inside up one level instead of deleting it.
    func delete(_ folder: ClipFolder, keepingContents: Bool) {
        let parentID = folder.parentID
        let sectionID = folder.sectionID
        let all = folders()
        let clips = allClips()

        if keepingContents {
            for child in all where child.parentID == folder.id { child.parentID = parentID }
            for clip in clips where clip.folderID == folder.id {
                setLocation(clip, folder: parentID, section: sectionID)
            }
        } else {
            let doomed = ClipFolder.subtree(of: folder.id, in: sectionID, among: all)
            for clip in clips {
                guard let id = clip.folderID, doomed.contains(id) else { continue }
                destroy(clip)
            }
            for child in all where child.id != folder.id && doomed.contains(child.id) {
                context.delete(child)
            }
        }
        context.delete(folder)
        save()
        refreshAllStats()
    }

    // MARK: Filing clips

    /// Puts a clip in a folder, at a section's top level, or back in the built-in history.
    func file(_ item: ClipItem, inFolder folderID: UUID?, section sectionID: UUID?) {
        guard !item.isDeleted, item.modelContext != nil else { return }
        let previous = item.folderID
        setLocation(item, folder: folderID, section: sectionID)
        save()
        refreshStats(from: previous)
        refreshStats(from: folderID)
    }

    private func setLocation(_ item: ClipItem, folder folderID: UUID?, section sectionID: UUID?) {
        item.folderID = folderID
        item.sectionID = sectionID
        item.isFiled = folderID != nil || sectionID != nil
    }

    private func destroy(_ item: ClipItem) {
        BlobStore.delete(item.blobFilenames)
        context.delete(item)
    }

    // MARK: Keeping the folder totals right

    /// Recomputes what one folder holds, then its parent, and so on to the top. Used when a single
    /// clip or folder moves: everything deeper is already correct.
    func refreshStats(from folderID: UUID?) {
        guard folderID != nil else { return }
        let all = folders()
        let clips = allClips()
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var current = folderID
        for _ in 0..<ClipFolder.maxDepth {
            guard let id = current, let folder = byID[id] else { break }
            let children = all.filter { $0.parentID == id }
            let inside = clips.filter { $0.folderID == id }
            folder.kindsMask = children.reduce(0) { $0 | $1.kindsMask } | inside.reduce(0) { $0 | $1.kind.bit }
            folder.itemCount = children.count + inside.count
            current = folder.parentID
        }
        save()
    }

    /// Recomputes every folder from the inside out. Used after a folder or section is deleted or
    /// moved, when several branches change at once.
    func refreshAllStats() {
        let all = folders()
        let clips = allClips()
        let ids = Set(all.map(\.id))

        // A folder or clip can't point at something that's gone; put strays back at the top level.
        for folder in all {
            if let parent = folder.parentID, !ids.contains(parent) { folder.parentID = nil }
        }
        for clip in clips {
            if let folder = clip.folderID, !ids.contains(folder) {
                setLocation(clip, folder: nil, section: clip.sectionID)
            }
        }

        var children: [UUID: [ClipFolder]] = [:]
        for folder in all { if let parent = folder.parentID { children[parent, default: []].append(folder) } }
        var inside: [UUID: [ClipItem]] = [:]
        for clip in clips { if let folder = clip.folderID { inside[folder, default: []].append(clip) } }

        // Depth first: a folder is only counted once everything inside it has been.
        func refresh(_ folder: ClipFolder, depth: Int) -> Int {
            guard depth < ClipFolder.maxDepth else { return 0 }
            let subfolders = children[folder.id] ?? []
            let clips = inside[folder.id] ?? []
            var mask = clips.reduce(0) { $0 | $1.kind.bit }
            for subfolder in subfolders { mask |= refresh(subfolder, depth: depth + 1) }
            folder.kindsMask = mask
            folder.itemCount = subfolders.count + clips.count
            return mask
        }
        for folder in all where folder.parentID == nil { _ = refresh(folder, depth: 0) }
        save()
    }
}
