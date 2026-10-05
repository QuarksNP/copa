import SwiftData
import SwiftUI

/// The black shape over the notch. Collapsed it looks exactly like the hardware notch;
/// on hover it springs open into the clipboard panel.
struct NotchView: View {
    @Environment(NotchController.self) private var notch
    @Environment(AppModel.self) private var app

    var body: some View {
        let expanded = notch.isExpanded
        let size = expanded ? NotchController.expandedSize
            : notch.activity != nil ? notch.activityShapeSize : notch.collapsedShapeSize
        let shape = NotchShape(
            topRadius: expanded ? NotchController.expandedTopRadius : NotchController.collapsedTopRadius,
            bottomRadius: expanded ? NotchController.expandedBottomRadius : NotchController.collapsedBottomRadius
        )

        ZStack(alignment: .top) {
            shape
                .fill(.black)
                // Without a real notch, stay invisible until opened (or showing an activity).
                .opacity(notch.hasNotch || expanded || notch.activity != nil ? 1 : 0)

            if !expanded, let activity = notch.activity {
                ActivityView(activity: activity)
                    .padding(.horizontal, NotchController.collapsedTopRadius + 10)
                    .frame(height: notch.notchSize.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

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
        .onDrop(of: PasteboardWriter.acceptedDropTypes, isTargeted: Bindable(notch).isDropTargeted) { providers in
            guard !notch.isDraggingFromCard else { return false }
            // Dropping while a section or folder is open puts it there, which is where the
            // user is looking. On the closed notch it goes to the history, as it always has.
            guard expanded else { return app.handleDrop(providers) }
            return app.handleDrop(providers, inFolder: notch.currentFolderID, section: notch.category.sectionID)
        }
        .animation(.easeOut(duration: 0.15), value: notch.isDropTargeted)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

/// Shown on both sides of the notch while a screenshot is being saved, like the Dynamic Island.
private struct ActivityView: View {
    let activity: NotchController.Activity
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack {
            // Left: what's happening.
            Group {
                switch activity {
                case .savingScreenshot:
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, options: .repeating)
                case .savedScreenshot(let url, let symbol):
                    if let url, let image = ImageCache.shared.image(at: url) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 26, height: 18)
                            .clipShape(.rect(cornerRadius: 4))
                    } else {
                        Image(systemName: symbol)
                            .foregroundStyle(.white)
                    }
                }
            }
            .transition(.scale.combined(with: .opacity))

            Spacer(minLength: 0)

            // Right: progress, then a checkmark.
            Group {
                switch activity {
                case .savingScreenshot:
                    HStack(spacing: 5) {
                        // Several screenshots on their way: show how many.
                        if app.screenshots.pendingCount > 1 {
                            Text(app.screenshots.pendingCount, format: .number)
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .contentTransition(.numericText())
                        }
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    .animation(.snappy, value: app.screenshots.pendingCount)
                case .savedScreenshot:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tint)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: activity)
    }
}

/// Header + category tabs + the path you're in + carousel.
private struct ExpandedNotchContent: View {
    @Environment(NotchController.self) private var notch
    @Environment(AppModel.self) private var app
    @Query(sort: \ClipItem.lastUsedAt, order: .reverse) private var allItems: [ClipItem]
    @Query(sort: \ClipFolder.createdAt) private var allFolders: [ClipFolder]
    @Query(sort: [SortDescriptor(\ClipSection.sortIndex), SortDescriptor(\ClipSection.createdAt)])
    private var sections: [ClipSection]

    /// Where the carousel is looking: the tab's section, and the folder opened inside it.
    private var sectionID: UUID? { notch.category.sectionID }
    private var folderID: UUID? { notch.currentFolderID }

    private var query: String { notch.searchText.trimmingCharacters(in: .whitespaces) }

    /// Searching, or asking for pinned clips, looks through everything below here rather than
    /// just this level — otherwise a clip you filed away would be impossible to find.
    private var isFlattened: Bool { !query.isEmpty || notch.showPinnedOnly }

    /// This folder and every folder inside it; at the top of a tab, the whole section.
    private var scope: Set<UUID> {
        ClipFolder.subtree(of: folderID, in: sectionID, among: allFolders)
    }

    private var visibleFolders: [ClipFolder] {
        // Pinning is about clips, so the pinned filter leaves folders out entirely.
        guard !notch.showPinnedOnly else { return [] }
        guard !query.isEmpty else {
            return allFolders.filter {
                $0.sectionID == sectionID && $0.parentID == folderID && notch.category.shows($0)
            }
        }
        let scope = scope
        return allFolders.filter {
            $0.sectionID == sectionID && $0.id != folderID && scope.contains($0.id)
                && notch.category.shows($0) && $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    private var visibleItems: [ClipItem] {
        let query = query
        let flattened = isFlattened
        let scope = flattened ? scope : []
        let filtered = allItems.filter { item in
            guard item.sectionID == sectionID, notch.category.shows(item) else { return false }
            // A loose clip belongs to the top level of its section, not inside any folder.
            let here = flattened
                ? (item.folderID.map(scope.contains) ?? (folderID == nil))
                : item.folderID == folderID
            return here
                && (!notch.showPinnedOnly || item.isPinned)
                && (query.isEmpty || item.searchableText.localizedCaseInsensitiveContains(query))
        }
        // Pinned clips always come first.
        return filtered.filter(\.isPinned) + filtered.filter { !$0.isPinned }
    }

    /// How many clips each tab holds, folders included.
    private var counts: [ClipCategory: Int] {
        var counts: [ClipCategory: Int] = [:]
        for item in allItems {
            if let id = item.sectionID {
                counts[.section(id), default: 0] += 1
            } else {
                counts[.all, default: 0] += 1
                counts[.kind(item.kind), default: 0] += 1
            }
        }
        return counts
    }

    /// The folders we're inside, outermost first.
    private var trail: [ClipFolder] {
        let byID = Dictionary(allFolders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return notch.folderPath.compactMap { byID[$0] }
    }

    private var currentSection: ClipSection? {
        sectionID.flatMap { id in sections.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            HStack(spacing: 10) {
                CategoryBar(sections: sections, counts: counts)
                NewSectionButton()
                PinFilterButton()
                SearchField()
            }
            PathBar(rootTitle: currentSection?.name ?? notch.category.title,
                    rootSymbol: currentSection?.symbol ?? notch.category.symbol,
                    sectionID: sectionID,
                    trail: trail,
                    folders: allFolders)
            CarouselView(folders: visibleFolders, items: visibleItems, allFolders: allFolders,
                         sections: sections, showsFolderChips: isFlattened)
        }
        .padding(.bottom, 12)
        // A folder or section can be deleted while we're looking inside it.
        .onChange(of: allFolders.map(\.id)) { _, ids in
            notch.trimPath(toExisting: Set(ids))
        }
        .onChange(of: sections.map(\.id)) { _, ids in
            if let sectionID, !ids.contains(sectionID) { notch.category = .all }
        }
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
