import Foundation

/// One entry of a markdown list. `marker` is "•" for a bullet, the source number ("3.") for an
/// ordered item, or a box for a task item. `blocks` is whatever the item holds, nested lists included.
public struct MessageMarkdownListItem: Equatable, Sendable {
    public let marker: String
    public let blocks: [MessageMarkdownBlock]
}

/// The structure of an agent's message, so a card can show its markdown as formatting instead of raw
/// `**`, `|`, and fences. Text keeps Foundation's inline attributes (emphasis, code, links) for the
/// app to style; this target decides nothing about color or font.
public indirect enum MessageMarkdownBlock: Equatable, Sendable {
    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case list([MessageMarkdownListItem])
    case quote([MessageMarkdownBlock])
    case code(String)
    /// `header` and every row have exactly `alignments.count` cells.
    case table(alignments: [PresentationIntent.TableColumn.Alignment], header: [AttributedString], rows: [[AttributedString]])
    case rule
}

/// Foundation's own CommonMark and GFM parser does the reading, so lists, quotes, and code nest as they
/// do on GitHub. The input is bounded (`CompletionPreview`) but often cut mid-structure: an unclosed
/// fence runs to the end, a short table row is padded, an unclosed `**` stays as typed, and block HTML
/// shows as typed, so no text disappears. Nothing here can fail.
public enum MessageMarkdown {
    /// Containers deeper than this flatten to paragraphs: a message of 20,000 `>` must not recurse
    /// that far through this builder or the views. Each list level counts twice (list and item).
    static let maximumDepth = 16

    public static func blocks(_ source: String) -> [MessageMarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: keepingLineBreaks(source), options: options) else {
            return [.paragraph(AttributedString(source))]
        }
        let leaves = parsed.runs[\.presentationIntent].map { intent, range in
            var text = AttributedString(parsed[range])
            text.presentationIntent = nil
            return Leaf(path: Array((intent?.components ?? []).reversed().prefix(maximumDepth + 1)), text: text)
        }
        return build(leaves[...], depth: 0)
    }

    /// The first line that has words, as the card's one-line Glance shows it, cut with "…" past
    /// `limit` characters of rendered text, so a cut can never leave a stray `**` behind. `isWhole`:
    /// that line is the entire message, so there is nothing to unfold.
    public static func firstLine(_ source: String, limit: Int) -> (line: AttributedString, isWhole: Bool) {
        let blocks = blocks(source)
        let lines = blocks.flatMap(textLines)
        guard var line = lines.first else {
            let first = source.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return (AttributedString(first), blocks.isEmpty)
        }
        let cut = line.characters.count > limit
        if cut {
            line = AttributedString(line[..<line.index(line.startIndex, offsetByCharacters: limit - 1)])
            while let last = line.characters.last, last.isWhitespace {
                line = AttributedString(line[..<line.index(line.endIndex, offsetByCharacters: -1)])
            }
            line.append(AttributedString("…"))
        }
        let holdsCode = blocks.contains { if case .code = $0 { true } else { false } }
        return (line, !cut && lines.count == 1 && !holdsCode)
    }

    private struct Leaf {
        /// The block's containers, outermost first; empty for block HTML, which has no intent.
        let path: [PresentationIntent.IntentType]
        let text: AttributedString

        var trimmed: AttributedString {
            var value = text
            while let last = value.characters.last, last.isNewline {
                value = AttributedString(value[..<value.index(value.endIndex, offsetByCharacters: -1)])
            }
            return value
        }
    }

    /// Agents break lines on purpose, so a line break inside a paragraph stays one (CommonMark would
    /// make it a space). Two trailing spaces are a hard break there and mean nothing at the end of any
    /// other block; `code` removes them from code. A line ending in `\` is a hard break already.
    private static func keepingLineBreaks(_ source: String) -> String {
        source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line in
            line.allSatisfy(\.isWhitespace) || line.last == "\\" ? String(line) : line + "  "
        }.joined(separator: "\n")
    }

    private static func build(_ leaves: ArraySlice<Leaf>, depth: Int) -> [MessageMarkdownBlock] {
        guard depth < maximumDepth else { return leaves.map { .paragraph($0.trimmed) } }
        return groups(leaves, depth: depth).flatMap { group -> [MessageMarkdownBlock] in
            guard let first = group.first, depth < first.path.count else {
                // Block HTML comes back as raw source, the added line-break marks included.
                return group.map { .paragraph(AttributedString(code($0.text))) }
            }
            switch first.path[depth].kind {
            case .paragraph:
                return group.map { .paragraph($0.trimmed) }
            case let .header(level):
                return group.map { .heading(level: level, text: $0.trimmed) }
            case .codeBlock:
                return group.map { .code(code($0.text)) }
            case .thematicBreak:
                return [.rule]
            case .blockQuote:
                return [.quote(build(group, depth: depth + 1))]
            case .orderedList:
                return [.list(items(group, depth: depth + 1, ordered: true))]
            case .unorderedList:
                return [.list(items(group, depth: depth + 1, ordered: false))]
            case let .table(columns):
                return [table(group, alignments: columns.map(\.alignment), depth: depth + 1)]
            default:
                return build(group, depth: depth + 1)
            }
        }
    }

    /// Consecutive leaves that share the container at `depth`.
    private static func groups(_ leaves: ArraySlice<Leaf>, depth: Int) -> [ArraySlice<Leaf>] {
        var result: [ArraySlice<Leaf>] = []
        var start = leaves.startIndex
        for index in leaves.indices where index > start {
            let before = leaves[index - 1], leaf = leaves[index]
            let same = depth < before.path.count && depth < leaf.path.count
                && before.path[depth].identity == leaf.path[depth].identity
            if !same {
                result.append(leaves[start..<index])
                start = index
            }
        }
        if start < leaves.endIndex { result.append(leaves[start...]) }
        return result
    }

    private static func items(_ leaves: ArraySlice<Leaf>, depth: Int, ordered: Bool) -> [MessageMarkdownListItem] {
        groups(leaves, depth: depth).map { group in
            var ordinal = 1
            if let first = group.first, depth < first.path.count, case let .listItem(value) = first.path[depth].kind {
                ordinal = value
            }
            let blocks = build(group, depth: depth + 1)
            if !ordered, case let .paragraph(text)? = blocks.first, let (box, rest) = taskItem(text) {
                return MessageMarkdownListItem(marker: box, blocks: [.paragraph(rest)] + blocks.dropFirst())
            }
            return MessageMarkdownListItem(marker: ordered ? "\(ordinal)." : "•", blocks: blocks)
        }
    }

    /// Foundation leaves `[x]` in the item's text.
    private static func taskItem(_ text: AttributedString) -> (String, AttributedString)? {
        for (prefix, box) in [("[ ] ", "☐"), ("[x] ", "☑"), ("[X] ", "☑")]
        where String(text.characters.prefix(prefix.count)) == prefix {
            return (box, AttributedString(text[text.index(text.startIndex, offsetByCharacters: prefix.count)...]))
        }
        return nil
    }

    private static func table(_ leaves: ArraySlice<Leaf>, alignments: [PresentationIntent.TableColumn.Alignment],
                              depth: Int) -> MessageMarkdownBlock {
        var header = Array(repeating: AttributedString(), count: alignments.count)
        var rows: [[AttributedString]] = []
        for rowLeaves in groups(leaves, depth: depth) {
            // An empty cell has no leaf at all, so cells go in by their column, not their order.
            var cells = Array(repeating: AttributedString(), count: alignments.count)
            for cell in rowLeaves where depth + 1 < cell.path.count {
                if case let .tableCell(column) = cell.path[depth + 1].kind, cells.indices.contains(column) {
                    cells[column] = cell.trimmed
                }
            }
            if let first = rowLeaves.first, depth < first.path.count, case .tableHeaderRow = first.path[depth].kind {
                header = cells
            } else {
                rows.append(cells)
            }
        }
        return .table(alignments: alignments, header: header, rows: rows)
    }

    /// Literal text without the marks `keepingLineBreaks` added or the closing newline.
    private static func code(_ text: AttributedString) -> String {
        var lines = String(text.characters).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { String($0.reversed().drop(while: \.isWhitespace).reversed()) }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Every visible line in reading order, without markers: a table row reads as its cells.
    private static func textLines(_ block: MessageMarkdownBlock) -> [AttributedString] {
        switch block {
        case let .paragraph(text), let .heading(_, text):
            return lines(text)
        case let .list(items):
            return items.flatMap { $0.blocks.flatMap(textLines) }
        case let .quote(blocks):
            return blocks.flatMap(textLines)
        case let .code(text):
            return text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
                .map { AttributedString($0.trimmingCharacters(in: .whitespaces)) }
        case let .table(_, header, rows):
            return ([header] + rows).map { cells in
                cells.filter { !$0.characters.isEmpty }.reduce(into: AttributedString()) { line, cell in
                    if !line.characters.isEmpty { line.append(AttributedString(" · ")) }
                    line.append(cell)
                }
            }
        case .rule:
            return []
        }
    }

    private static func lines(_ text: AttributedString) -> [AttributedString] {
        var result: [AttributedString] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetByCharacters: 1)
            if text.characters[index].isNewline {
                result.append(AttributedString(text[start..<index]))
                start = next
            }
            index = next
        }
        result.append(AttributedString(text[start..<text.endIndex]))
        return result.filter { !$0.characters.allSatisfy(\.isWhitespace) }
    }
}
