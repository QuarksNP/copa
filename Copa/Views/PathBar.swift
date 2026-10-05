import SwiftUI

/// The row under the tabs: where in the section you are, and the way back out. It's always there,
/// even at the top level, so the panel never changes height when you step into a folder.
///
/// Each step is also a place to drop a clip or a folder, which moves it out to that level.
struct PathBar: View {
    /// The tab itself, which is the first step of the path.
    let rootTitle: String
    let rootSymbol: String
    /// The section the tab shows, if it's one the user made.
    let sectionID: UUID?
    /// The folders we're inside, outermost first.
    let trail: [ClipFolder]
    /// Every folder, to resolve one being dragged onto a step of the path.
    let folders: [ClipFolder]

    @Environment(NotchController.self) private var notch
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 6) {
            if !trail.isEmpty {
                Button(action: notch.goUp) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.08), in: .circle)
                }
                .buttonStyle(.plain)
                .help("Back (Esc)")
                .transition(.scale.combined(with: .opacity))
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        crumb(title: rootTitle, symbol: rootSymbol, depth: 0, tint: nil)
                        ForEach(Array(trail.enumerated()), id: \.element.id) { index, folder in
                            Image(systemName: "chevron.compact.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            crumb(title: folder.name, symbol: "folder.fill", depth: index + 1,
                                  tint: Color(hex: folder.colorHex))
                        }
                    }
                    .padding(.trailing, 4)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A long path scrolls to show where you actually are.
                .onChange(of: trail.count) { _, _ in
                    guard notch.isExpanded, let last = trail.last else { return }
                    withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(last.id.uuidString, anchor: .trailing) }
                }
            }

            Button(action: newFolder) {
                Label("New Folder", systemImage: "folder.badge.plus")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(.white.opacity(0.08), in: .capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .fixedSize()
            .help("New folder here")
        }
        .frame(height: 24)
        .animation(.snappy(duration: 0.25), value: trail.count)
    }

    private func crumb(title: String, symbol: String, depth: Int, tint: Color?) -> some View {
        // Step 0 is the tab; step n is the nth folder we opened.
        let folderID = depth == 0 ? nil : trail[depth - 1].id
        return CrumbButton(title: title, symbol: symbol, tint: tint, isHere: depth == trail.count,
                           folderID: folderID, sectionID: sectionID, folders: folders,
                           go: { notch.go(toDepth: depth) })
            .id(folderID?.uuidString ?? "root")
    }

    private func newFolder() {
        let folder = app.store.addFolder(name: "New Folder", in: sectionID, parentID: notch.currentFolderID)
        notch.editing = .folder(folder.id)
    }
}

/// One step of the path. Click to jump there; drop a clip or folder on it to move it out to here.
private struct CrumbButton: View {
    let title: String
    let symbol: String
    let tint: Color?
    let isHere: Bool
    let folderID: UUID?
    let sectionID: UUID?
    let folders: [ClipFolder]
    let go: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(NotchController.self) private var notch
    @State private var isTargeted = false

    private var acceptsDrop: Bool {
        ClipFolder.canDrop(notch.dragging, into: folderID, section: sectionID, among: folders)
    }

    var body: some View {
        Button(action: go) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 11.5, weight: isHere ? .semibold : .regular))
            .foregroundStyle(isHere ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(.white.opacity(isTargeted && acceptsDrop ? 0.2 : isHere ? 0.1 : 0), in: .capsule)
            .overlay {
                if isTargeted && acceptsDrop { Capsule().strokeBorder(Color.accentColor, lineWidth: 1) }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .onDrop(of: PasteboardWriter.acceptedDropTypes, isTargeted: $isTargeted) { providers in
            guard acceptsDrop else { return false }
            let dragging = notch.dragging
            notch.endDrag()
            return withAnimation(.snappy) {
                app.acceptDrop(providers, dragging: dragging, inFolder: folderID, section: sectionID)
            }
        }
    }
}
