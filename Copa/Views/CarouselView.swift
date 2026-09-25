import SwiftUI

/// A horizontally scrolling row of clip cards that snaps to each card.
struct CarouselView: View {
    let items: [ClipItem]
    @Environment(NotchController.self) private var notch

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 10) {
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
