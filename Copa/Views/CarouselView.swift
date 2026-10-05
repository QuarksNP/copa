import SwiftUI

/// A horizontally scrolling row that snaps to each card. Folders come first, then the clips —
/// inside a folder it works exactly the same way, with that folder's contents.
struct CarouselView: View {
    /// The folders at this level (or, while searching, the ones below here that match).
    let folders: [ClipFolder]
    /// The clips at this level.
    let items: [ClipItem]
    /// Every folder and section, for the menus on the cards.
    let allFolders: [ClipFolder]
    let sections: [ClipSection]
    /// True when the list gathers clips from several folders, so cards say where they're filed.
    let showsFolderChips: Bool

    @Environment(NotchController.self) private var notch
    @Environment(AppModel.self) private var app

    /// A screenshot is on its way and belongs in the current tab. Screenshots arrive loose in the
    /// history, so the placeholder only belongs at the top level of the built-in tabs.
    private var showsPendingScreenshot: Bool {
        app.screenshots.pendingCount > 0 && notch.searchText.isEmpty && !notch.showPinnedOnly
            && notch.currentFolderID == nil && notch.category.sectionID == nil
            && (notch.category == .all || notch.category == .kind(.image))
    }

    private var folderNames: [UUID: String] {
        guard showsFolderChips else { return [:] }
        return Dictionary(allFolders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        Group {
            if folders.isEmpty && items.isEmpty && !showsPendingScreenshot {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 10) {
                            if showsPendingScreenshot {
                                PendingScreenshotCard()
                                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                            }
                            ForEach(folders) { folder in
                                FolderCard(folder: folder, sections: sections, folders: allFolders)
                                    .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                        content
                                            .scaleEffect(phase.isIdentity ? 1 : 0.88)
                                            .opacity(phase.isIdentity ? 1 : 0.4)
                                    }
                            }
                            ForEach(items) { item in
                                ClipCard(item: item, sections: sections, folders: allFolders,
                                         folderName: item.folderID.flatMap { folderNames[$0] })
                                    .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                        content
                                            .scaleEffect(phase.isIdentity ? 1 : 0.88)
                                            .opacity(phase.isIdentity ? 1 : 0.4)
                                    }
                            }
                        }
                        .scrollTargetLayout()
                        .animation(.snappy, value: showsPendingScreenshot)
                        .padding(.vertical, 6)
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                    .contentMargins(.horizontal, 4, for: .scrollContent)
                    // Coming back from the preview, start where the preview left off.
                    .onAppear {
                        guard notch.isExpanded, let target = notch.selection else { return }
                        proxy.scrollTo(target.scrollID)
                    }
                    // Keep the card chosen with the arrow keys in view.
                    .onChange(of: notch.selection) { _, target in
                        // Only while open: scrolling during the close animation leaves content behind.
                        guard let target, notch.isExpanded else { return }
                        withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(target.scrollID) }
                    }
                }
                // Start from the beginning whenever the tab, folder or filter changes.
                .id(notch.locationID)
                .transition(.opacity)
            }
        }
        .frame(height: ClipCard.size.height + 12)
    }

    private var emptyState: some View {
        let isSearching = !notch.searchText.isEmpty
        let inFolder = notch.currentFolderID != nil
        return VStack(spacing: 6) {
            Image(systemName: isSearching ? "magnifyingglass" : inFolder ? "folder" : notch.category.symbol)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: notch.locationID)
            Text(isSearching ? "No Results" : inFolder ? "Empty Folder" : "Nothing Here Yet")
                .font(.headline)
            Text(emptyHint(isSearching: isSearching, inFolder: inFolder))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    private func emptyHint(isSearching: Bool, inFolder: Bool) -> String {
        if isSearching { return "Try a different search." }
        if inFolder || notch.category.sectionID != nil { return "Right-click a clip and choose Move to." }
        return "Copy something, or drop it on the notch."
    }
}

/// Placeholder shown while macOS finishes saving a screenshot.
private struct PendingScreenshotCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)
            ProgressView()
                .controlSize(.small)
            Text("Saving screenshot…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(width: ClipCard.size.width, height: ClipCard.size.height)
        .background(.white.opacity(0.065), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }
}
