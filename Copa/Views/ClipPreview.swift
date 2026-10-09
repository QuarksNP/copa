import AppKit
import SwiftData
import SwiftUI

/// The open panel showing one card in full, instead of the carousel: the whole text, the image at
/// a real size, every path of a file clip. Space opens it, Esc or the back button leaves it.
///
/// The pane follows the selected card rather than remembering one, so ← → flip through the
/// carousel, and deleting the card shown moves the pane to its neighbour.
struct PreviewPane: View {
    /// The clip to show, when the selected card is one.
    let item: ClipItem?
    /// The folder to show, when the selected card is a folder instead.
    let folder: ClipFolder?
    /// Which card this is in the carousel, counting from 1, for "3 of 24".
    let position: Int?
    let total: Int

    @Environment(AppModel.self) private var app
    @Environment(NotchController.self) private var notch
    @State private var showCopied = false

    /// A card can be deleted while its preview is on screen; reading it then would crash.
    private var liveItem: ClipItem? {
        guard let item, !item.isDeleted, item.modelContext != nil else { return nil }
        return item
    }

    private var liveFolder: ClipFolder? {
        guard let folder, !folder.isDeleted, folder.modelContext != nil else { return nil }
        return folder
    }

    var body: some View {
        VStack(spacing: 10) {
            toolbar
                .onChange(of: item?.id) { _, _ in showCopied = false }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white.opacity(0.05), in: .rect(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.white.opacity(0.08))
                }
            footer
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: notch.closePreview) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.08), in: .circle)
            }
            .buttonStyle(.plain)
            .help("Back to the cards (Esc)")

            Image(systemName: liveFolder != nil ? "folder.fill" : (liveItem?.kind.symbol ?? "square.dashed"))
                .font(.system(size: 13))
                .foregroundStyle(liveFolder.map { AnyShapeStyle(Color(hex: $0.colorHex)) } ?? AnyShapeStyle(.tint))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 8)

            if let position, total > 1 {
                Text("\(position) of \(total)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("← → show the card before or after this one")
            }
            actions
        }
        .frame(height: 26)
    }

    private var title: String {
        liveFolder?.name ?? liveItem?.displayName ?? "Nothing to Show"
    }

    @ViewBuilder
    private var actions: some View {
        if let folder = liveFolder {
            pill("Open", symbol: "folder", prominent: true) { notch.open(folderID: folder.id) }
        } else if let item = liveItem {
            if item.kind == .link, let url = item.url,
               ["http", "https", "ftp"].contains(url.scheme?.lowercased() ?? "") {
                pill("Open", symbol: "safari") { NSWorkspace.shared.open(url) }
            }
            if item.kind == .file || item.kind == .image {
                pill("Show", symbol: "folder") {
                    let urls = item.kind == .file ? item.fileURLs : [item.imageURL].compactMap { $0 }
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
            }
            Button {
                withAnimation(.snappy) { app.store.togglePin(item) }
            } label: {
                Image(systemName: item.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(item.isPinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(item.isPinned ? 0.12 : 0.08), in: .circle)
            }
            .buttonStyle(.plain)
            .help(item.isPinned ? "Unpin" : "Pin")

            pill(showCopied ? "Copied" : "Copy", symbol: showCopied ? "checkmark" : "doc.on.doc",
                 prominent: true) { copy(item) }
                .help("Copy to the clipboard · Return copies and closes Copa")
        }
    }

    private func pill(_ title: String, symbol: String, prominent: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(.tint.opacity(prominent ? 0.3 : 0.16), in: .capsule)
                .overlay(Capsule().strokeBorder(.tint.opacity(prominent ? 0.5 : 0.3)))
                .contentShape(.capsule)
                // The accent itself, not `.tint`: taking the tint from the tint is a loop.
                .tint(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .contentTransition(.symbolEffect(.replace))
    }

    private func copy(_ item: ClipItem) {
        app.copy(item)
        withAnimation(.snappy(duration: 0.2)) { showCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeOut(duration: 0.25)) { showCopied = false }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let folder = liveFolder {
            FolderSummary(folder: folder)
        } else if let item = liveItem {
            switch item.kind {
            case .text:
                TextPane(item: item)
            case .color:
                ColorPane(item: item)
            case .link:
                LinkPane(item: item)
            case .image:
                ImagePane(item: item)
            case .file:
                FilePane(item: item)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Nothing to Show")
                    .font(.headline)
            }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 6) {
            if let item = liveItem {
                if let bundleID = item.sourceBundleID, let icon = ImageCache.shared.appIcon(bundleID: bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 13, height: 13)
                }
                if let name = item.sourceAppName {
                    Text(name)
                }
                Text("·")
                Text(item.lastUsedAt.formatted(date: .abbreviated, time: .shortened))
                if item.customName != nil {
                    Text("·")
                    Text("Renamed in Copa")
                }
            } else if let folder = liveFolder {
                Text(folder.itemCount == 1 ? "1 item" : "\(folder.itemCount) items")
                Text("·")
                Text("Added \(folder.createdAt.formatted(date: .abbreviated, time: .shortened))")
            }
            Spacer(minLength: 0)
            Text("Space closes · ← → move")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(height: 14)
    }
}

// MARK: - Text

/// The whole text of a clip, in an AppKit text view: it lays out a long clip without the stall a
/// SwiftUI `Text` would cause, and the text stays selectable so part of it can be taken.
/// Markdown is shown formatted; the code view shows it as it was written.
private struct TextPane: View {
    let item: ClipItem

    @AppStorage("previewMonospaced") private var monospaced = false
    @AppStorage(Markdown.enabledKey) private var formatsMarkdown = true
    @State private var content = Content()

    var body: some View {
        VStack(spacing: 0) {
            TextViewer(text: content.shown, formatted: content.formatted?.text,
                       monospaced: monospaced, key: content.key)
            Divider().opacity(0.3)
            HStack(spacing: 6) {
                if content.formatted != nil {
                    Text("Markdown ·")
                }
                Text(summary)
                if content.truncated {
                    Text("· showing the first \(Self.maxCharacters.formatted()) characters")
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Button {
                    monospaced.toggle()
                } label: {
                    Image(systemName: monospaced ? "textformat.alt" : "textformat")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 18)
                        .background(.white.opacity(monospaced ? 0.12 : 0), in: .rect(cornerRadius: 5))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(monospaced ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help(content.formatted != nil ? "Show the Markdown as written" : "Show as code")
            }
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 24)
        }
        // Counting, cutting and formatting happen off the main thread: a clip can be megabytes long.
        .task(id: "\(item.id) \(formatsMarkdown)") {
            let text = item.text ?? ""
            let formats = item.isMarkdown && formatsMarkdown
            content = Content()
            var measured = await Self.prepare(text, formatting: formats)
            measured.key = "\(item.id) \(formats)"
            content = measured
        }
    }

    private var summary: String {
        let characters = content.characters == 1 ? "1 character" : "\(content.characters.formatted()) characters"
        guard content.lines > 1 else { return characters }
        return "\(characters) · \(content.lines.formatted()) lines"
    }

    /// What the pane shows, with the clip's real size alongside it.
    private struct Content: Sendable {
        /// The clip this text came from, so the text view knows when it has something new to lay
        /// out. Empty until the text has been measured, which happens off the main thread.
        var key = ""
        var shown = ""
        var characters = 0
        var lines = 0
        var truncated = false
        /// The text formatted, when it's Markdown.
        var formatted: Formatted?
    }

    /// Lets the formatted text cross back from the background task: it's built there and only
    /// read on the main thread afterwards.
    private struct Formatted: @unchecked Sendable { let text: NSAttributedString }

    /// Longer clips are cut here: laying out megabytes of text would stall the panel, and the
    /// footer says how much there is in total.
    nonisolated static let maxCharacters = 100_000

    private static func prepare(_ text: String, formatting: Bool) async -> Content {
        await Task.detached(priority: .userInitiated) { measure(text, formatting: formatting) }.value
    }

    nonisolated private static func measure(_ text: String, formatting: Bool) -> Content {
        let characters = text.count
        let truncated = characters > maxCharacters
        let shown = truncated ? String(text.prefix(maxCharacters)) : text
        return Content(shown: shown, characters: characters,
                       lines: shown.lazy.filter(\.isNewline).count + 1, truncated: truncated,
                       formatted: formatting ? Formatted(text: Markdown.render(shown, theme: .pane)) : nil)
    }
}

/// Scrollable, selectable, read-only text. Read-only on purpose: the panel's keyboard shortcuts
/// (Space, Esc, ← →) keep working while it has focus because nothing is typed into it.
private struct TextViewer: NSViewRepresentable {
    let text: String
    /// Shown instead of `text` unless `monospaced` asks for the text as it was written.
    let formatted: NSAttributedString?
    let monospaced: Bool
    /// Changes when a different clip is shown, so the text is only handed over when it has to be.
    let key: String

    final class Coordinator { var shown: String? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        // The panel is always dark, whatever the system appearance is.
        scroll.appearance = NSAppearance(named: .darkAqua)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.drawsBackground = false
        textView.isEditable = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.textColor = .labelColor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, let storage = textView.textStorage else { return }
        let font: NSFont = monospaced
            ? .monospacedSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 13)
        let identity = key + String(monospaced)
        // The second half catches a text view that ended up empty anyway, rather than leaving
        // the pane blank until the next clip.
        let isEmpty = storage.length == 0
        guard context.coordinator.shown != identity || (isEmpty && !text.isEmpty) else { return }
        context.coordinator.shown = identity
        if let formatted, !monospaced {
            storage.setAttributedString(formatted)
        } else {
            // Replaced whole, attributes included, so nothing carries over from formatted text.
            storage.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor,
            ]))
        }
        // Code blocks, quotes and tables switch the view to TextKit 1, which lays out a long
        // text all at once unless it's told it may skip what isn't on screen. (Asking a
        // TextKit 2 view for its layout manager would switch it too, so only ask once it has.)
        if textView.textLayoutManager == nil {
            textView.layoutManager?.allowsNonContiguousLayout = true
        }
        textView.scroll(.zero)
    }
}

// MARK: - Link

/// The page image, title and whole address of a copied link.
private struct LinkPane: View {
    let item: ClipItem

    private var host: String {
        (item.url?.host() ?? "").replacingOccurrences(of: "www.", with: "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let url = item.linkImageURL, let image = ImageCache.shared.image(at: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320, maxHeight: .infinity)
                    .clipShape(.rect(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if let url = item.linkIconURL, let icon = ImageCache.shared.image(at: url) {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                            .clipShape(.rect(cornerRadius: 5))
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: 18))
                            .foregroundStyle(.tint)
                    }
                    Text(host.isEmpty ? "Link" : host)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if let title = item.linkTitle, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(3)
                }
                Text(item.urlString ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tint)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(16)
    }
}

// MARK: - Image

/// The copied image, as large as the pane allows. The stored thumbnail (480 px) shows straight
/// away while a sharper copy is decoded off the main thread; nothing is kept once the pane goes.
private struct ImagePane: View {
    let item: ClipItem

    @State private var full: NSImage?

    private var thumbnail: NSImage? {
        item.thumbnailURL.flatMap { ImageCache.shared.image(at: $0) }
    }

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let image = full ?? thumbnail {
                    if item.isSVG {
                        // Icons and logos: a light backdrop keeps dark or transparent art visible.
                        Color(white: 0.92)
                            .overlay {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .padding(20)
                            }
                            .clipShape(.rect(cornerRadius: 12))
                    } else {
                        // A small image stays its own size instead of being blown up to fill
                        // the pane; a big one is fitted inside it.
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: max(CGFloat(item.imageWidth), 1),
                                   maxHeight: max(CGFloat(item.imageHeight), 1))
                    }
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(caption)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .task(id: item.id) {
            full = nil
            guard let url = item.imageURL else { return }
            full = await Self.load(url, isSVG: item.isSVG)
        }
    }

    private var caption: String {
        var parts: [String] = []
        if item.imageWidth > 0 { parts.append("\(Int(item.imageWidth)) × \(Int(item.imageHeight)) px") }
        if item.isSVG { parts.append("SVG (vector)") }
        if let url = item.imageURL, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            parts.append(size.formatted(.byteCount(style: .file)))
        }
        return parts.joined(separator: " · ")
    }

    /// Decodes at most 1600 px off the main thread: enough for a sharp pane on a Retina screen,
    /// without pulling a whole screenshot into memory at full size.
    private static func load(_ url: URL, isSVG: Bool) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { decode(url, isSVG: isSVG) }.value?.image
    }

    /// Lets the decoded image cross back from the background task: it's built there and only
    /// read on the main thread afterwards.
    private struct Decoded: @unchecked Sendable { let image: NSImage }

    nonisolated private static func decode(_ url: URL, isSVG: Bool) -> Decoded? {
        // An SVG is a vector: NSImage draws it crisply at any size, so leave it alone.
        if isSVG { return NSImage(contentsOf: url).map(Decoded.init) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return Decoded(image: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)))
    }
}

// MARK: - Color

/// The copied color, large, with the values that can be read off it.
private struct ColorPane: View {
    let item: ClipItem

    private var hex: String { item.colorHex ?? "#000000" }

    var body: some View {
        HStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(hex: hex))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.18)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 14) {
                value("Hex", hex.uppercased())
                value("RGB", rgb)
                if let text = item.text, text.uppercased() != hex.uppercased() {
                    value("Copied as", text)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 260, alignment: .topLeading)
        }
        .padding(20)
    }

    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(text)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    /// "rgb(10, 132, 255)", or "rgba(…)" when the color is see-through.
    private var rgb: String {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits, radix: 16) ?? 0
        let hasAlpha = digits.count == 8
        let r = (value >> (hasAlpha ? 24 : 16)) & 0xFF
        let g = (value >> (hasAlpha ? 16 : 8)) & 0xFF
        let b = (value >> (hasAlpha ? 8 : 0)) & 0xFF
        guard hasAlpha else { return "rgb(\(r), \(g), \(b))" }
        let alpha = (Double(value & 0xFF) / 255 * 100).rounded() / 100
        return "rgba(\(r), \(g), \(b), \(alpha.formatted()))"
    }
}

// MARK: - File

/// Every path a file clip holds, with what's on disk right now.
private struct FilePane: View {
    let item: ClipItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(item.filePaths, id: \.self) { path in
                    FileRow(path: path)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

private struct FileRow: View {
    let path: String

    @State private var detail = ""

    private var exists: Bool { FileManager.default.fileExists(atPath: path) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: ImageCache.shared.fileIcon(path: path))
                .resizable()
                .frame(width: 56, height: 56)
                .opacity(exists ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 4) {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                if exists {
                    Text(detail)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else {
                    Text("File moved or deleted")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        // Asking the disk about the file happens off the main thread.
        .task(id: path) { detail = await Self.describe(path) }
    }

    private static func describe(_ path: String) async -> String {
        await Task.detached(priority: .utility) { details(of: path) }.value
    }

    nonisolated private static func details(of path: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey,
                                                             .contentModificationDateKey, .isDirectoryKey])
        else { return "" }
        var parts: [String] = []
        if values.isDirectory == true {
            parts.append("Folder")
        } else if let size = values.fileSize ?? values.totalFileAllocatedSize {
            parts.append(size.formatted(.byteCount(style: .file)))
        }
        if let modified = values.contentModificationDate {
            parts.append("Modified \(modified.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Folder

/// What a folder holds, read from the counts it keeps: a folder is never walked to draw it.
private struct FolderSummary: View {
    let folder: ClipFolder

    private var color: Color { Color(hex: folder.colorHex) }

    var body: some View {
        VStack(spacing: 14) {
            FolderShape()
                .fill(LinearGradient(colors: [color.mix(with: .white, by: 0.12), color],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 128, height: 100)
            Text(folder.name)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(2)
            Text(folder.itemCount == 1 ? "1 item inside" : "\(folder.itemCount) items inside")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if !folder.kinds.isEmpty {
                HStack(spacing: 10) {
                    ForEach(folder.kinds) { kind in
                        Label(kind.title, systemImage: kind.symbol)
                            .labelStyle(.iconOnly)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .help(kind.title)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
