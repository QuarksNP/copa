import SwiftData
import SwiftUI

/// The black shape over the notch. Collapsed it looks exactly like the hardware notch;
/// on hover it springs open into the clipboard panel.
struct NotchView: View {
    @Environment(NotchController.self) private var notch
    @Environment(AppModel.self) private var app

    var body: some View {
        let expanded = notch.isExpanded
        let size = expanded ? NotchController.expandedSize : notch.collapsedShapeSize
        let shape = NotchShape(
            topRadius: expanded ? NotchController.expandedTopRadius : NotchController.collapsedTopRadius,
            bottomRadius: expanded ? NotchController.expandedBottomRadius : NotchController.collapsedBottomRadius
        )

        ZStack(alignment: .top) {
            shape
                .fill(.black)
                // Without a real notch, stay invisible until opened.
                .opacity(notch.hasNotch || expanded ? 1 : 0)

            if expanded {
                ExpandedNotchContent()
                    .padding(.horizontal, NotchController.expandedTopRadius + 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }

            if notch.isDropTargeted && !notch.isDraggingFromCard {
                DropOverlay()
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .contentShape(shape)
        .shadow(color: .black.opacity(expanded ? 0.55 : 0), radius: 18, y: 8)
        .onHover { notch.hoverChanged($0) }
        .onDrop(of: PasteboardWriter.acceptedDropTypes, isTargeted: Bindable(notch).isDropTargeted) { providers in
            guard !notch.isDraggingFromCard else { return false }
            return app.handleDrop(providers)
        }
        .animation(.easeOut(duration: 0.15), value: notch.isDropTargeted)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

/// Header + category tabs + carousel.
private struct ExpandedNotchContent: View {
    @Environment(NotchController.self) private var notch
    @Environment(AppModel.self) private var app
    @Query(sort: \ClipItem.lastUsedAt, order: .reverse) private var allItems: [ClipItem]

    private var visibleItems: [ClipItem] {
        let query = notch.searchText.trimmingCharacters(in: .whitespaces)
        let filtered = allItems.filter { item in
            notch.category.contains(item)
                && (!notch.showPinnedOnly || item.isPinned)
                && (query.isEmpty || item.searchableText.localizedCaseInsensitiveContains(query))
        }
        // Pinned clips always come first.
        return filtered.filter(\.isPinned) + filtered.filter { !$0.isPinned }
    }

    private var counts: [ClipCategory: Int] {
        var counts: [ClipCategory: Int] = [.all: allItems.count]
        for item in allItems { counts[.kind(item.kind), default: 0] += 1 }
        return counts
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            HStack(spacing: 10) {
                CategoryBar(counts: counts)
                Spacer(minLength: 8)
                PinFilterButton()
                SearchField()
            }
            CarouselView(items: visibleItems)
        }
        .padding(.bottom, 12)
    }

    /// Sits on either side of the physical notch.
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard.fill")
                    .foregroundStyle(.tint)
                Text("Copa")
                    .font(.system(size: 13, weight: .semibold))
                if app.monitor.isPaused {
                    Text("Paused")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.25), in: .capsule)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: notch.notchSize.width + 20)
            NotchMenu()
        }
        .frame(height: notch.notchSize.height)
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.7))
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, options: .repeating)
                Text("Drop to save in Copa")
                    .font(.headline)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(10)
        }
    }
}

private struct PinFilterButton: View {
    @Environment(NotchController.self) private var notch

    var body: some View {
        Button {
            withAnimation(.snappy) { notch.showPinnedOnly.toggle() }
        } label: {
            Image(systemName: notch.showPinnedOnly ? "pin.fill" : "pin")
                .frame(width: 26, height: 26)
                .foregroundStyle(notch.showPinnedOnly ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .background(.white.opacity(notch.showPinnedOnly ? 0.12 : 0.06), in: .circle)
        }
        .buttonStyle(.plain)
        .help("Show pinned only")
    }
}

private struct SearchField: View {
    @Environment(NotchController.self) private var notch
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: Bindable(notch).searchText)
                .textFieldStyle(.plain)
                .focused($focused)
            if !notch.searchText.isEmpty {
                Button {
                    notch.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9)
        .frame(width: 150, height: 26)
        .background(.white.opacity(focused ? 0.12 : 0.07), in: .capsule)
        .overlay(Capsule().strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

private struct NotchMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(NotchController.self) private var notch

    var body: some View {
        Menu {
            Button("Settings…", systemImage: "gearshape") {
                notch.collapse()
                SettingsWindowController.shared.show(app: app)
            }
            Toggle("Pause Capture", systemImage: "pause.circle", isOn: Bindable(app.monitor).isPaused)
            Divider()
            Button("Quit Copa", systemImage: "power") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
