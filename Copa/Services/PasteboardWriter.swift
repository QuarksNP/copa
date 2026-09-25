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
            if let url = item.imageURL, let image = NSImage(contentsOf: url) {
                pasteboard.writeObjects([image])
            }
        case .file:
            pasteboard.writeObjects(item.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.map { $0 as NSURL })
        }
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
