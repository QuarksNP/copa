import AppKit
import SwiftUI

/// Text written in Markdown (a chatbot's answer, a README, notes from Obsidian) is shown formatted
/// and pastes as formatted text into apps that take it (Notes, Mail, Pages, Google Docs). Apps that
/// take plain text (code editors, Terminal) still get the Markdown itself.
///
/// Everything here can run off the main thread, and only looks at a bounded part of a clip.
nonisolated enum Markdown {
    /// The "Format Markdown" setting. On unless the user turns it off.
    static let enabledKey = "formatMarkdown"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    // MARK: Recognizing it

    /// How much of a clip is read to decide. Markdown shows itself in the first few lines.
    private static let sampleLength = 8_000

    /// Whether this text is written in Markdown. Two different kinds of Markdown are needed
    /// (a heading and a list, bold text and a link…): one alone is too common in plain text, and
    /// text where many lines end in `;`, `{` or `}` is code, whatever else it has.
    static func detect(_ text: String) -> Bool {
        var found = Feature()
        var lines = 0
        var codeLines = 0
        var inFence = false
        for line in text.prefix(sampleLength).split(whereSeparator: \.isNewline) {
            let line = line.drop { $0 == " " || $0 == "\t" }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                found.insert(.fence)
                inFence.toggle()
                continue
            }
            guard !inFence, !line.isEmpty else { continue }
            lines += 1
            if let last = line.last, ";{}".contains(last) { codeLines += 1 }

            if isHeading(line) {
                found.insert(.heading)
            } else if isBullet(line) {
                found.insert(.bullet)
            } else if isNumbered(line) {
                found.insert(.numbered)
            } else if line.hasPrefix("> ") {
                found.insert(.quote)
            } else if isTableDivider(line) {
                found.insert(.table)
            }
            // The patterns only run on lines that could match: regexes are slow next to a plain search.
            if !found.contains(.bold), line.contains("**"),
               line.contains(#/\*\*[^\s*](?:[^*]*[^\s*])?\*\*/#) { found.insert(.bold) }
            if !found.contains(.code), line.contains("`"), line.contains(#/`[^`]+`/#) { found.insert(.code) }
            if !found.contains(.link), line.contains("]("),
               line.contains(#/\[[^\]]+\]\((?:https?:|mailto:|#|/|\./)[^)\s]*\)/#) { found.insert(.link) }
        }
        guard lines > 0, codeLines * 3 <= lines else { return false }
        return found.rawValue.nonzeroBitCount >= 2
    }

    private struct Feature: OptionSet {
        let rawValue: Int
        static let heading = Feature(rawValue: 1 << 0)
        static let bullet = Feature(rawValue: 1 << 1)
        static let numbered = Feature(rawValue: 1 << 2)
        static let quote = Feature(rawValue: 1 << 3)
        static let table = Feature(rawValue: 1 << 4)
        static let fence = Feature(rawValue: 1 << 5)
        static let bold = Feature(rawValue: 1 << 6)
        static let code = Feature(rawValue: 1 << 7)
        static let link = Feature(rawValue: 1 << 8)
    }

    /// "# Title" to "###### Title".
    private static func isHeading(_ line: Substring) -> Bool {
        let hashes = line.prefix { $0 == "#" }.count
        let rest = line.dropFirst(hashes)
        return (1...6).contains(hashes) && rest.first == " " && rest.contains { !$0.isWhitespace }
    }

    /// "- item", "* item" or "+ item".
    private static func isBullet(_ line: Substring) -> Bool {
        guard let first = line.first, "-*+".contains(first) else { return false }
        let rest = line.dropFirst()
        return rest.first == " " && rest.contains { !$0.isWhitespace }
    }

    /// "1. item" or "1) item".
    private static func isNumbered(_ line: Substring) -> Bool {
        let digits = line.prefix { $0.isASCII && $0.isNumber }.count
        let rest = line.dropFirst(digits)
        guard (1...9).contains(digits), let mark = rest.first, mark == "." || mark == ")" else { return false }
        return rest.dropFirst().first == " "
    }

    /// The line under a table's header: "| --- | :-: |".
    private static func isTableDivider(_ line: Substring) -> Bool {
        line.contains("|") && line.contains("-") && line.allSatisfy { "|-: \t".contains($0) }
    }

    // MARK: Reading it

    /// One stretch of text with a single look, and where it sits: Foundation parses the Markdown,
    /// and this turns its nesting of blocks into what a renderer needs to know.
    private struct Piece {
        var text: String
        var block: Block
        var inline: InlinePresentationIntent
        var link: URL?
        /// The first piece of a new paragraph (or heading, line of code, table cell…).
        var startsBlock: Bool
        /// "•", "2." or a checkbox, on the first paragraph of a list item.
        var marker: String?
    }

    private struct Block {
        /// The innermost block. Pieces with the same id belong to the same paragraph.
        var id = -1
        var heading = 0
        var isCode = false
        var isRule = false
        /// The block quotes this sits in, outermost first.
        var quotes: [Int] = []
        var listDepth = 0
        var listItem: Int?
        /// The item's number, when its list is numbered.
        var ordinal: Int?
        var table: Int?
        var columns: [PresentationIntent.TableColumn] = []
        var row = 0
        var column = 0
        var isHeaderRow = false

        init() {}

        init(_ intent: PresentationIntent?) {
            guard let intent else { return }
            let components = intent.components  // innermost first
            id = components.first?.identity ?? -1
            for (index, component) in components.enumerated() {
                switch component.kind {
                case .header(let level): heading = level
                case .codeBlock: isCode = true
                case .thematicBreak: isRule = true
                case .blockQuote: quotes.insert(component.identity, at: 0)
                case .orderedList, .unorderedList: listDepth += 1
                case .listItem(let number):
                    guard listItem == nil else { break }
                    listItem = component.identity
                    if index + 1 < components.count, case .orderedList = components[index + 1].kind {
                        ordinal = number
                    }
                case .table(let columns):
                    table = component.identity
                    self.columns = columns
                case .tableHeaderRow: isHeaderRow = true
                case .tableRow(let index): row = index
                case .tableCell(let index): column = index
                default: break
                }
            }
        }
    }

    private static let bullets = ["•", "◦", "▪"]

    private static func pieces(of text: String) -> [Piece]? {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else { return nil }

        var pieces: [Piece] = []
        var lastBlock: Int?
        var markedItems = Set<Int>()
        for run in parsed.runs {
            let block = Block(run.presentationIntent)
            let inline = run.inlinePresentationIntent ?? []
            var text = String(parsed[run.range].characters)
            // Keep the copied text's own line breaks: Markdown would join lines into one paragraph,
            // but in a clip a line break is almost always meant.
            if inline.contains(.softBreak) || inline.contains(.lineBreak) { text = "\n" }
            if block.isCode, text.hasSuffix("\n") { text.removeLast() }
            if block.isRule { text = "" }

            let startsBlock = block.id != lastBlock
            lastBlock = block.id
            var marker: String?
            if startsBlock, let item = block.listItem, markedItems.insert(item).inserted {
                marker = block.ordinal.map { "\($0)." } ?? bullets[(block.listDepth - 1) % bullets.count]
                // GitHub's task lists: "- [ ] to do" and "- [x] done".
                for (box, symbol) in [("[ ] ", "☐"), ("[x] ", "☑"), ("[X] ", "☑")] where text.hasPrefix(box) {
                    marker = symbol
                    text.removeFirst(box.count)
                }
            }
            pieces.append(Piece(text: text, block: block, inline: inline, link: run.link,
                                startsBlock: startsBlock, marker: marker))
        }
        return pieces
    }

    // MARK: Formatted text

    /// Where the formatted text is going: the always-dark preview pane, or another app's
    /// document, where it should look like that app's own text.
    enum Theme: Sendable {
        case pane
        case document
    }

    /// Fonts and colors for a theme. Built on the spot rather than kept, so nothing here has to
    /// cross threads.
    private struct Style {
        let size: CGFloat
        let body: NSFont
        let mono: NSFont
        /// Nil leaves the color to whoever shows the text (black on paper, white in dark mode).
        let text: NSColor?
        let secondary: NSColor
        let fill: NSColor
        let line: NSColor

        init(_ theme: Theme) {
            switch theme {
            case .pane:
                size = 13
                body = .systemFont(ofSize: 13)
                mono = .monospacedSystemFont(ofSize: 12, weight: .regular)
                text = .labelColor
                secondary = .secondaryLabelColor
                fill = NSColor(white: 1, alpha: 0.08)
                line = NSColor(white: 1, alpha: 0.22)
            case .document:
                // Named fonts: other apps don't all know the system font by its internal name.
                size = 13
                body = NSFont(name: "Helvetica Neue", size: 13) ?? .systemFont(ofSize: 13)
                mono = NSFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
                text = nil
                secondary = .gray
                fill = NSColor(white: 0.5, alpha: 0.12)
                line = NSColor(white: 0.5, alpha: 0.45)
            }
        }

        func heading(_ level: Int) -> NSFont {
            let scale: CGFloat = switch level {
            case 1: 1.6
            case 2: 1.35
            case 3: 1.15
            default: 1
            }
            return body.with([.bold], size: (size * scale).rounded())
        }
    }

    /// The whole text, formatted. Headings, lists, quotes, code blocks and tables become real
    /// paragraphs, so the result can be shown in a text view or written out as RTF or HTML.
    static func render(_ text: String, theme: Theme) -> NSAttributedString {
        let style = Style(theme)
        guard let pieces = pieces(of: text) else {
            return NSAttributedString(string: text, attributes: [.font: style.body])
        }

        let output = NSMutableAttributedString()
        var previous = Block()
        var paragraph = NSParagraphStyle.default
        var lastAttributes: [NSAttributedString.Key: Any] = [:]
        // Paragraphs that share one of these are drawn as one box: a whole code block, quote or table.
        var boxes: [Int: NSTextBlock] = [:]
        var tables: [Int: NSTextTable] = [:]

        func box(_ id: Int, make: () -> NSTextBlock) -> NSTextBlock {
            if let box = boxes[id] { return box }
            let box = make()
            boxes[id] = box
            return box
        }

        for piece in pieces {
            let block = piece.block
            if piece.startsBlock {
                if output.length > 0 {
                    output.append(NSAttributedString(string: "\n", attributes: lastAttributes))
                }
                paragraph = paragraphStyle(for: piece, after: previous, isFirst: output.length == 0,
                                           style: style, box: box, tables: &tables)
                previous = block
            }

            var font = block.heading > 0 ? style.heading(block.heading) : (block.isCode ? style.mono : style.body)
            var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph]
            if piece.inline.contains(.code) {
                font = style.mono.with([], size: (font.pointSize * 0.92).rounded())
                attributes[.backgroundColor] = style.fill
            }
            var traits: NSFontDescriptor.SymbolicTraits = []
            if piece.inline.contains(.stronglyEmphasized) || block.isHeaderRow { traits.insert(.bold) }
            if piece.inline.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty { font = font.with(traits, size: font.pointSize) }
            attributes[.font] = font
            if let color = block.quotes.isEmpty ? style.text : style.secondary {
                attributes[.foregroundColor] = color
            }
            if piece.inline.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = piece.link { attributes[.link] = link }

            if let marker = piece.marker {
                var markerAttributes = attributes
                markerAttributes[.font] = style.body
                markerAttributes.removeValue(forKey: .link)
                output.append(NSAttributedString(string: marker + "\t", attributes: markerAttributes))
            }
            // A line break inside a paragraph stays inside it, rather than starting a new one
            // with the space that comes after a paragraph. Code keeps one paragraph per line.
            let text = block.isCode ? piece.text : piece.text.replacingOccurrences(of: "\n", with: "\u{2028}")
            output.append(NSAttributedString(string: block.isRule ? " " : text, attributes: attributes))
            lastAttributes = attributes
            lastAttributes.removeValue(forKey: .link)
            lastAttributes.removeValue(forKey: .backgroundColor)
        }
        return output
    }

    private static func paragraphStyle(for piece: Piece, after previous: Block, isFirst: Bool, style: Style,
                                       box: (Int, () -> NSTextBlock) -> NSTextBlock,
                                       tables: inout [Int: NSTextTable]) -> NSParagraphStyle {
        let block = piece.block
        let size = style.size
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = block.isCode ? 1 : 1.12
        paragraph.paragraphSpacing = size * 0.7

        if block.heading > 0 {
            paragraph.paragraphSpacingBefore = isFirst ? 0 : size * 0.5
            paragraph.paragraphSpacing = size * 0.35
        } else if previous.listItem != nil, block.listItem == nil, previous.quotes == block.quotes {
            // The space a list's items leave between them is too little after the list.
            paragraph.paragraphSpacingBefore = size * 0.4
        } else if block.table == nil, !block.isCode, previous.table != nil || previous.isCode {
            // A box's last line has no space after it, so that the box stays in one piece.
            // (A table cell would take the space inside itself, so a table goes without.)
            paragraph.paragraphSpacingBefore = size * 0.7
        }

        if block.listItem != nil {
            let indent = CGFloat(block.listDepth) * 22
            paragraph.headIndent = indent
            paragraph.firstLineHeadIndent = piece.marker != nil ? indent - 22 : indent
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            paragraph.paragraphSpacing = size * 0.3
        }

        var textBlocks: [NSTextBlock] = block.quotes.map { id in
            box(id) {
                let quote = fullWidthBox()
                quote.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                quote.setBorderColor(style.line, for: .minX)
                quote.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
                quote.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
                return quote
            }
        }

        if block.isCode {
            paragraph.paragraphSpacing = 0
            textBlocks.append(box(block.id) {
                let code = fullWidthBox()
                code.backgroundColor = style.fill
                code.setWidth(10, type: .absoluteValueType, for: .padding)
                return code
            })
        } else if block.isRule {
            paragraph.paragraphSpacing = size * 0.7
            textBlocks.append(box(block.id) {
                let rule = fullWidthBox()
                rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                rule.setBorderColor(style.line, for: .maxY)
                return rule
            })
        } else if let tableID = block.table {
            paragraph.paragraphSpacing = 0
            let table = tables[tableID] ?? {
                let table = NSTextTable()
                table.numberOfColumns = max(block.columns.count, 1)
                table.collapsesBorders = true
                tables[tableID] = table
                return table
            }()
            let cell = NSTextTableBlock(table: table, startingRow: block.row, rowSpan: 1,
                                        startingColumn: block.column, columnSpan: 1)
            cell.setWidth(1, type: .absoluteValueType, for: .border)
            cell.setBorderColor(style.line)
            cell.setWidth(6, type: .absoluteValueType, for: .padding)
            if block.isHeaderRow { cell.backgroundColor = style.fill }
            textBlocks.append(cell)
            if block.column < block.columns.count {
                paragraph.alignment = switch block.columns[block.column].alignment {
                case .center: .center
                case .right: .right
                default: .left
                }
            }
        }
        paragraph.textBlocks = textBlocks
        return paragraph
    }

    /// A box as wide as the text, rather than as wide as what's in it.
    private static func fullWidthBox() -> NSTextBlock {
        let box = NSTextBlock()
        box.setContentWidth(100, type: .percentageValueType)
        return box
    }

    // MARK: Pasting it

    /// Longer clips paste as plain text: formatting megabytes would hold up the copy.
    static let maxRichTextLength = 300_000

    /// The text as RTF (Notes, Mail, Pages, Word) and HTML (web apps such as Gmail or Google
    /// Docs). Nil when the clip is too long to format quickly.
    static func richText(_ text: String) -> (rtf: Data, html: Data?)? {
        guard text.utf8.count <= maxRichTextLength else { return nil }
        let formatted = render(text, theme: .document)
        let range = NSRange(location: 0, length: formatted.length)
        guard let rtf = formatted.rtf(from: range, documentAttributes: [:]) else { return nil }
        let html = try? formatted.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        return (rtf, html)
    }

    // MARK: Cards

    /// A few lines for a card: headings in bold, list items with their bullets, one line per
    /// paragraph. Bold, italic and code are left to SwiftUI's `Text`, which draws them itself.
    /// Pass a short prefix: a card only has room for a few lines.
    static func cardText(_ text: String) -> AttributedString {
        guard let pieces = pieces(of: text) else { return AttributedString(text) }
        var output = AttributedString()
        var previous: Block?
        for piece in pieces {
            let block = piece.block
            if piece.startsBlock {
                if let previous {
                    let sameRow = block.table != nil && block.table == previous.table
                        && block.row == previous.row && block.isHeaderRow == previous.isHeaderRow
                    output.append(AttributedString(sameRow ? "   " : "\n"))
                }
                previous = block
                if !block.quotes.isEmpty { output.append(AttributedString("▎ ")) }
                if let marker = piece.marker {
                    let indent = String(repeating: "   ", count: max(block.listDepth - 1, 0))
                    output.append(AttributedString(indent + marker + " "))
                }
            }

            var run = AttributedString(block.isRule ? "———" : piece.text)
            var inline = piece.inline
            if block.isHeaderRow { inline.insert(.stronglyEmphasized) }
            if !inline.isEmpty { run.inlinePresentationIntent = inline }
            if block.heading > 0 { run.swiftUI.font = .system(size: 13, weight: .bold) }
            if block.isCode { run.swiftUI.font = .system(size: 11, design: .monospaced) }
            if block.isCode || block.isRule || !block.quotes.isEmpty { run.swiftUI.foregroundColor = .secondary }
            // Not a real link: clicking a card copies it, and a link would open instead.
            if piece.link != nil { run.swiftUI.foregroundColor = .accentColor }
            output.append(run)
        }
        return output
    }
}

private extension NSFont {
    /// This font with extra traits (bold, italic) at a size, keeping the traits it already has.
    nonisolated func with(_ traits: NSFontDescriptor.SymbolicTraits, size: CGFloat) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: size) ?? self
    }
}
