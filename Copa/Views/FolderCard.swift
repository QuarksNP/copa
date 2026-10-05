import SwiftData
import SwiftUI

/// A folder in the carousel. Click to look inside, drag it into another folder, drop clips on it
/// to file them, right-click for the rest. Folders come before the clips, the way pinned clips do.
struct FolderCard: View {
    let folder: ClipFolder
    /// Everything a clip can be moved into, for the menus.
    let sections: [ClipSection]
    let folders: [ClipFolder]

    @Environment(AppModel.self) private var app
    @Environment(NotchController.self) private var notch
    @State private var isHovered = false
    @State private var isTargeted = false

    private var isSelected: Bool { notch.selection == .folder(folder.id) }
    private var isEditing: Bool { notch.editing == .folder(folder.id) }
    private var color: Color { Color(hex: folder.colorHex) }

    private var acceptsDrop: Bool {
        ClipFolder.canDrop(notch.dragging, into: folder.id, section: folder.sectionID, among: folders)
    }

    var body: some View {
        // Like a clip card, a folder can be drawn once more while it animates away, after its
        // data is gone. Reading it then would crash, so draw an empty space instead.
        if folder.isDeleted || folder.modelContext == nil {
            Color.clear.frame(width: ClipCard.size.width, height: ClipCard.size.height)
        } else {
            card
        }
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            paper
            label
        }
        .frame(width: ClipCard.size.width, height: ClipCard.size.height)
        .overlay {
            FolderShape()
                .strokeBorder(isSelected ? Color.accentColor : .white.opacity(isHovered ? 0.35 : 0.14),
                              lineWidth: isSelected ? 2 : 1)
        }
        .overlay { if isTargeted && acceptsDrop { dropHighlight } }
        .animation(.snappy(duration: 0.2), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .contentShape(FolderShape())
        .scaleEffect(isHovered ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture { if !isEditing { notch.open(folderID: folder.id) } }
        .onDrag {
            notch.isDraggingFromCard = true
            notch.dragging = .folder(folder.id)
            // A folder has nothing of its own to paste elsewhere. Handing over its name gives the
            // drag something to carry, and a type the other folders accept.
            return NSItemProvider(object: folder.name as NSString)
        }
        .onDrop(of: PasteboardWriter.acceptedDropTypes, isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .contextMenu { contextMenu }
        .help("Click to open · Drag to move · Drop clips to file them here")
    }

    /// The folder itself: the back, a sheet of paper peeking out, then the front pocket.
    private var paper: some View {
        ZStack(alignment: .top) {
            FolderShape()
                .fill(LinearGradient(colors: [color.mix(with: .white, by: 0.12), color],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.9))
                .overlay(alignment: .top) { pages }
                .padding(.horizontal, 16)
                .padding(.top, 26)
                .padding(.bottom, 54)
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 18,
                                   bottomTrailingRadius: 18, topTrailingRadius: 12)
                .fill(LinearGradient(colors: [color.mix(with: .white, by: 0.22), color.mix(with: .black, by: 0.08)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(.top, 72)
        }
    }

    /// Faint lines on the sheet, so an empty folder still looks like it holds paper.
    private var pages: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<3, id: \.self) { row in
                Capsule()
                    .fill(.black.opacity(0.14))
                    .frame(width: row == 2 ? 34 : 60, height: 4)
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    if isEditing {
                        NameEditor(target: .folder(folder.id), name: folder.name,
                                   font: .system(size: 12, weight: .semibold)) { name in
                            app.store.rename(folder, to: name)
                        }
                    } else {
                        Text(folder.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)
                    }
                    Text(folder.isEmpty ? "Empty" : "^[\(folder.itemCount) item](inflect: true)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 0)
                // What's inside, at a glance.
                HStack(spacing: 3) {
                    ForEach(folder.kinds) { kind in
                        Image(systemName: kind.symbol)
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.bottom, 1)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var dropHighlight: some View {
        FolderShape()
            .fill(.black.opacity(0.35))
            .overlay {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                FolderShape()
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            }
    }

    // MARK: Actions

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard acceptsDrop else { return false }
        let dragging = notch.dragging
        notch.endDrag()
        return withAnimation(.snappy) {
            app.acceptDrop(providers, dragging: dragging, inFolder: folder.id, section: folder.sectionID)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open", systemImage: "folder") { notch.open(folderID: folder.id) }
        Button("New Folder Inside", systemImage: "folder.badge.plus") {
            let new = app.store.addFolder(name: "New Folder", in: folder.sectionID, parentID: folder.id)
            notch.open(folderID: folder.id)
            notch.editing = .folder(new.id)
        }
        Button("Rename…", systemImage: "pencil") { notch.editing = .folder(folder.id) }
        Menu("Color", systemImage: "paintpalette") {
            ForEach(ClipFolder.palette) { paint in
                Button(paint.name) { app.store.setColor(folder, to: paint.hex) }
            }
        }
        MoveFolderMenu(folder: folder, folders: folders)
        Divider()
        if folder.isEmpty {
            Button("Delete Folder", systemImage: "trash", role: .destructive) {
                withAnimation(.snappy) { app.store.delete(folder, keepingContents: false) }
            }
        } else {
            // Spelled out, because one of these throws away everything inside.
            Button("Delete Folder, Keep Clips", systemImage: "folder.badge.minus") {
                withAnimation(.snappy) { app.store.delete(folder, keepingContents: true) }
            }
            Button("Delete Folder & Contents", systemImage: "trash", role: .destructive) {
                withAnimation(.snappy) { app.store.delete(folder, keepingContents: false) }
            }
        }
    }
}
