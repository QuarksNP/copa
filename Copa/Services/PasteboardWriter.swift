import AppKit
import UniformTypeIdentifiers

/// Puts a saved clip back on the clipboard, and builds drag items for dragging clips out of the notch.
enum PasteboardWriter {

    static func copy(_ item: ClipItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .text, .color:
            pasteboard.setString(item.text ?? "", forType: .string)
        case .link:
            if let url = item.url { pasteboard.writeObjects([url as NSURL]) }
            pasteboard.setString(item.urlString ?? item.text ?? "", forType: .string)
        case .image:
            guard let url = item.imageURL else { return }
            if item.isSVG, let data = try? Data(contentsOf: url) {
                writeSVG(data, code: item.text, to: pasteboard)
            } else if url.pathExtension == "png", let data = try? Data(contentsOf: url) {
                // Already PNG: hand it over as-is instead of converting it.
                pasteboard.setData(data, forType: .png)
            } else if let image = NSImage(contentsOf: url) {
                pasteboard.writeObjects([image])
            }
        case .file:
            pasteboard.writeObjects(item.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.map { $0 as NSURL })
        }
    }

    /// Every app gets the SVG in the form it understands: design apps take the vector and apps
    /// that only accept pictures take a sharp PNG. SVG that was copied as code also goes back as
    /// code (for Figma and code editors); otherwise text is left out, so text-first apps like
    /// Notes or Messages paste the picture rather than its source.
    private static func writeSVG(_ data: Data, code: String?, to pasteboard: NSPasteboard) {
        let item = NSPasteboardItem()
        item.setData(data, forType: .init(UTType.svg.identifier))
        if let code {
            item.setString(code, forType: .string)
        }
        if let image = NSImage(data: data) {
            // Render at 2× (up to 2048 px) so it stays crisp on Retina screens.
            let longest = max(image.size.width, image.size.height)
            if let png = BlobStore.renderPNG(image, maxPixelSize: min(max(longest * 2, 256), 2048)) {
                item.setData(png, forType: .png)
            }
        }
        pasteboard.writeObjects([item])
    }

    /// What other apps receive when a card is dragged out of Copa.
    static func itemProvider(for item: ClipItem) -> NSItemProvider {
        switch item.kind {
        case .text, .color:
            return NSItemProvider(object: (item.text ?? "") as NSString)
        case .link:
            guard let url = item.url else { return NSItemProvider(object: (item.text ?? "") as NSString) }
            let provider = NSItemProvider(object: url as NSURL)
            provider.suggestedName = url.host()
            return provider
        case .image:
            guard let url = item.imageURL, let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
            provider.suggestedName = "Copa Image"
            return provider
        case .file:
            guard let url = item.fileURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return NSItemProvider() }
            return NSItemProvider(object: url as NSURL)
        }
    }

    // MARK: Dropping onto the notch

    static let acceptedDropTypes: [UTType] = [.fileURL, .image, .url, .plainText]

    /// Turns things dropped on the notch into clips.
    static func payloads(from providers: [NSItemProvider], completion: @escaping @MainActor (ClipPayload) -> Void) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    let payload = ClipClassifier.payload(fromFiles: [url])
                    Task { @MainActor in completion(payload) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in completion(.image(data)) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in completion(.link(url, original: url.absoluteString)) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    guard let string, !string.isEmpty else { return }
                    Task { @MainActor in completion(ClipClassifier.payload(fromString: string)) }
                }
            }
        }
    }
}
