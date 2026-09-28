import SwiftUI

/// A horizontally scrolling row of clip cards that snaps to each card.
struct CarouselView: View {
    let items: [ClipItem]
    @Environment(NotchController.self) private var notch
    @Environment(AppModel.self) private var app

    /// A screenshot is on its way and belongs in the current tab.
    private var showsPendingScreenshot: Bool {
        app.screenshots.pendingCount > 0 && notch.searchText.isEmpty && !notch.showPinnedOnly
            && (notch.category == .all || notch.category == .kind(.image))
    }

    var body: some View {
        Group {
            if items.isEmpty && !showsPendingScreenshot {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 10) {
                            if showsPendingScreenshot {
                                PendingScreenshotCard()
                                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                            }
                            ForEach(items) { item in
                                ClipCard(item: item)
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
                    // Keep the card chosen with the arrow keys in view.
                    .onChange(of: notch.selection) { _, id in
                        guard let id else { return }
                        withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(id) }
                    }
                }
                // Start from the beginning whenever the tab or filter changes.
                .id(notch.category.id + String(notch.showPinnedOnly))
                .transition(.opacity)
            }
        }
        .frame(height: ClipCard.size.height + 12)
        .onChange(of: items.map(\.id), initial: true) { _, ids in
            notch.visibleItemIDs = ids
        }
    }

    private var emptyState: some View {
        let isSearching = !notch.searchText.isEmpty
        return VStack(spacing: 6) {
            Image(systemName: isSearching ? "magnifyingglass" : notch.category.symbol)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: notch.category)
            Text(isSearching ? "No Results" : "Nothing Here Yet")
                .font(.headline)
            Text(isSearching ? "Try a different search." : "Copy something, or drop it on the notch.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
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
