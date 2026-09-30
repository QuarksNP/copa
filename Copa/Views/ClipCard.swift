import SwiftData
import SwiftUI

/// One clip in the carousel. Click to copy, drag to use it anywhere, right-click for more.
struct ClipCard: View {
    static let size = CGSize(width: 156, height: 172)

    let item: ClipItem
    @Environment(AppModel.self) private var app
    @Environment(NotchController.self) private var notch
    @State private var isHovered = false
    @State private var showCopied = false

    private var isSelected: Bool { notch.selection == item.id }

    var body: some View {
        // A deleted clip can be drawn once more during its removal animation, when its data is
        // already gone; reading it then would crash, so draw an empty space instead.
        if item.isDeleted || item.modelContext == nil {
            Color.clear.frame(width: Self.size.width, height: Self.size.height)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if notch.editingItemID == item.id {
                NameEditor(item: item)
            } else {
                footer
            }
        }
        .padding(10)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.white.opacity(isHovered ? 0.11 : 0.065), in: .rect(cornerRadius: 18))
        .overlay {
            // Blue ring = the card the keyboard acts on. Hover just brightens the card.
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isSelected ? Color.accentColor : .white.opacity(isHovered ? 0.2 : 0.08),
                              lineWidth: isSelected ? 2 : 1)
        }
        .animation(.snappy(duration: 0.2), value: isSelected)
        .overlay { if showCopied { copiedOverlay } }
        .contentShape(.rect(cornerRadius: 18))
        .scaleEffect(isHovered ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: copy)
        .onDrag {
            notch.isDraggingFromCard = true
            return PasteboardWriter.itemProvider(for: item)
        }
        .contextMenu { contextMenu }
        .help("Click to copy · Drag to use")
    }

    // MARK: Preview per kind

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                if let name = item.customName {
                    nameLabel(name)
                }
                // The card shows ~7 lines, so don't lay out more text than that (clips can be huge).
                Text((item.text ?? "").prefix(600))
                    .font(.system(size: 12))
                    .lineLimit(item.customName == nil ? 7 : 5)
                    .foregroundStyle(item.customName == nil ? .primary : .secondary)
            }

        case .link:
            LinkPreview(item: item)

        case .image:
            VStack(alignment: .leading, spacing: 6) {
                if item.isSVG, let url = item.thumbnailURL, let image = ImageCache.shared.image(at: url) {
                    // Icons and logos: show the whole drawing on a light backdrop, so dark or
                    // transparent SVGs stay visible on the dark card.
                    Color(white: 0.92)
                        .overlay {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding(10)
                        }
                        .overlay(alignment: .topLeading) {
                            Text("SVG")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.55), in: .capsule)
                                .padding(6)
                        }
                        .clipShape(.rect(cornerRadius: 10))
                } else if let url = item.thumbnailURL, let image = ImageCache.shared.image(at: url) {
                    // Fill the available space and crop, without letting the image grow the card.
                    Color.clear
                        .overlay {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                        }
                        .clipShape(.rect(cornerRadius: 10))
                } else {
                    placeholder("photo")
                }
                if let name = item.customName {
                    nameLabel(name)
                }
            }

        case .file:
            FilePreview(paths: item.filePaths, name: item.customName)

        case .color:
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hex: item.colorHex ?? "#000000"))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
                if let name = item.customName {
                    nameLabel(name)
                }
                Text(item.colorHex ?? "")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                if let text = item.text, text.uppercased() != item.colorHex {
                    Text(text)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func nameLabel(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
    }

    private func placeholder(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 30))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if let bundleID = item.sourceBundleID, let icon = ImageCache.shared.appIcon(bundleID: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(footerText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tint)
            }
        }
    }

    private var footerText: String {
        let time = item.lastUsedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        if item.kind == .image, item.imageWidth > 0 {
            return "\(Int(item.imageWidth))×\(Int(item.imageHeight)) · \(time)"
        }
        return time
    }

    private var copiedOverlay: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(.black.opacity(0.6))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.tint)
                        .symbolEffect(.bounce, value: showCopied)
                    Text("Copied")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    // MARK: Actions

    private func copy() {
        notch.selectedItemID = item.id
        app.copy(item)
        withAnimation(.spring(response: 0.3)) { showCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(0.9))
            withAnimation(.easeOut(duration: 0.25)) { showCopied = false }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Copy", systemImage: "doc.on.doc", action: copy)
        Button(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin") {
            withAnimation(.snappy) { app.store.togglePin(item) }
        }
        Button("Rename…", systemImage: "pencil") {
            notch.editingItemID = item.id
        }
        if item.customName != nil {
            Button("Reset Name", systemImage: "arrow.uturn.backward") {
                withAnimation(.snappy) { app.store.rename(item, to: "") }
            }
        }
        if item.kind == .link, let url = item.url, ["http", "https", "ftp"].contains(url.scheme?.lowercased() ?? "") {
            Button("Open Link", systemImage: "safari") { NSWorkspace.shared.open(url) }
        }
        if item.kind == .file || item.kind == .image {
            Button("Show in Finder", systemImage: "folder") {
                let urls = item.kind == .file ? item.fileURLs : [item.imageURL].compactMap { $0 }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            withAnimation(.snappy) { app.store.delete(item) }
        }
    }
}

/// Inline text field shown in place of the card footer while renaming.
/// Return saves, Esc cancels, clicking elsewhere saves.
private struct NameEditor: View {
    let item: ClipItem
    @Environment(AppModel.self) private var app
    @Environment(NotchController.self) private var notch
    @State private var draft: String
    @FocusState private var focused: Bool

    init(item: ClipItem) {
        self.item = item
        _draft = State(initialValue: item.displayName)
    }

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .focused($focused)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(.white.opacity(0.1), in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1))
            .onSubmit { finish(save: true) }
            .onExitCommand { finish(save: false) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish(save: true) }
            }
            .onAppear {
                notch.focusPanel()
                // Focus on the next run loop, once the panel has become key.
                DispatchQueue.main.async { focused = true }
            }
            .onDisappear { finish(save: true) }
    }

    private func finish(save: Bool) {
        guard notch.editingItemID == item.id else { return }
        if save { app.store.rename(item, to: draft) }
        notch.editingItemID = nil
    }
}

/// Page image, site icon and title of a copied link. Falls back to a globe while loading or offline.
private struct LinkPreview: View {
    let item: ClipItem
    @Environment(AppModel.self) private var app

    private var host: String {
        (item.url?.host() ?? "Link").replacingOccurrences(of: "www.", with: "")
    }

    var body: some View {
        let pageImage = item.linkImageURL.flatMap { ImageCache.shared.image(at: $0) }
        let icon = item.linkIconURL.flatMap { ImageCache.shared.image(at: $0) }
        let title = item.customName ?? item.linkTitle.flatMap { $0.isEmpty ? nil : $0 }

        Group {
            if let pageImage {
                // Rich preview: page image on top, then icon + title and the site name.
                VStack(alignment: .leading, spacing: 6) {
                    Color.clear
                        .frame(height: 72)
                        .overlay {
                            Image(nsImage: pageImage)
                                .resizable()
                                .scaledToFill()
                        }
                        .clipShape(.rect(cornerRadius: 10))
                    HStack(alignment: .top, spacing: 6) {
                        siteIcon(icon, size: 16)
                        Text(title ?? host)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(2)
                    }
                    Text(host)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                // Compact preview: big icon, title (or domain) and the address.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        siteIcon(icon, size: 22)
                        if app.linkPreviews.isLoading(item) {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    Text(title ?? host)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(3)
                    Text(title == nil ? (item.urlString ?? "") : host)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(title == nil ? 3 : 1)
                }
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.25), value: item.linkPreviewFetched)
        .onAppear { app.linkPreviews.loadIfNeeded(item) }
    }

    @ViewBuilder
    private func siteIcon(_ icon: NSImage?, size: CGFloat) -> some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: size / 4.5))
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Finder icon and name of the copied file(s).
private struct FilePreview: View {
    let paths: [String]
    let name: String?

    var body: some View {
        let first = paths.first ?? ""
        let exists = FileManager.default.fileExists(atPath: first)
        VStack(alignment: .leading, spacing: 6) {
            Image(nsImage: ImageCache.shared.fileIcon(path: first))
                .resizable()
                .frame(width: 52, height: 52)
                .opacity(exists ? 1 : 0.4)
            Text(name ?? (first as NSString).lastPathComponent)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
            if paths.count > 1 {
                Text("+\(paths.count - 1) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
            } else if !exists {
                Text("File moved or deleted")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else {
                Text((first as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }
}

extension Color {
    /// Creates a color from "#RRGGBB" or "#RRGGBBAA".
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits, radix: 16) ?? 0
        let hasAlpha = digits.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
