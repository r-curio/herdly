import Foundation

/// The block structure of an agent's last message, so the result card can show its markdown as
/// formatting instead of raw `**`, `|`, and fences. Inline syntax (emphasis, code spans, links) stays
/// in each block's text for the app to style; this only splits lines into blocks.
///
/// The input is already bounded (`CompletionPreview`) and is often cut mid-structure, so every
/// construct tolerates a missing end: an unclosed fence runs to the end, a short table row is padded,
/// and a lone `|` line without a separator row stays a paragraph. Nothing here can fail.
public enum MessageMarkdownBlock: Equatable, Sendable {
    /// Consecutive lines, joined by "\n": agents break lines on purpose, so soft breaks are kept.
    case paragraph(String)
    case heading(level: Int, text: String)
    /// `marker` is "•" for any bullet, the source number ("1.") for an ordered item, or a box for a
    /// task item. `depth` is the nesting level from the indent, 0 at the margin.
    case listItem(marker: String, depth: Int, text: String)
    case quote(String)
    case code(String)
    /// Every row has exactly `header.count` cells.
    case table(header: [String], rows: [[String]])
    case rule
}

public enum MessageMarkdown {
    public static func blocks(_ source: String) -> [MessageMarkdownBlock] {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline).map(String.init)
        var blocks: [MessageMarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
            } else if let fence = codeFence(trimmed) {
                flushParagraph()
                let indent = leadingSpaces(line)
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(String(lines[index].dropFirst(min(indent, leadingSpaces(lines[index])))))
                    index += 1
                }
                index += 1 // The closing fence, when there is one.
                blocks.append(.code(body.joined(separator: "\n")))
            } else if let (level, text) = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: level, text: text))
                index += 1
            } else if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
            } else if trimmed.contains("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    let rowCells = cells(row)
                    rows.append(Array((rowCells + Array(repeating: "", count: header.count)).prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let quoteLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quoteLine.hasPrefix(">") else { break }
                    var rest = quoteLine.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
            } else if let item = listItem(line) {
                flushParagraph()
                var text = item.text
                index += 1
                // Indented lines that start no new block continue the item.
                while index < lines.count {
                    let next = lines[index]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    guard leadingSpaces(next) > item.indent, !nextTrimmed.isEmpty, listItem(next) == nil,
                          codeFence(nextTrimmed) == nil else { break }
                    text += "\n" + nextTrimmed
                    index += 1
                }
                blocks.append(.listItem(marker: item.marker, depth: min(item.indent / 2, 3), text: text))
            } else {
                paragraph.append(trimmed)
                index += 1
            }
        }
        flushParagraph()
        return blocks
    }

    /// The fence a line opens ("```" or "~~~"), which only the same characters close.
    private static func codeFence(_ trimmed: String) -> String? {
        for fence in ["```", "~~~"] where trimmed.hasPrefix(fence) { return fence }
        return nil
    }

    private static func heading(_ trimmed: String) -> (Int, String)? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of "#" is decoration.
        let closed = text.replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
        return (hashes, closed)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        let parts = cells(trimmed)
        return !parts.isEmpty && parts.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" } && cell.contains("-")
        }
    }

    /// A row's cells: the outer pipes dropped, split on each pipe outside a code span, `\|` kept as
    /// a literal pipe.
    private static func cells(_ trimmed: String) -> [String] {
        var row = Substring(trimmed)
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|") && !row.hasSuffix("\\|") { row = row.dropLast() }
        var result: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for character in row {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                current.append(character)
            } else if character == "|" && !inCode {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    private static func listItem(_ line: String) -> (marker: String, indent: Int, text: String)? {
        let indent = leadingSpaces(line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var marker: String
        var rest: Substring
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
            marker = "•"
            rest = trimmed.dropFirst(2)
        } else {
            let digits = trimmed.prefix(while: \.isASCII).prefix(while: \.isNumber)
            let after = trimmed.dropFirst(digits.count)
            guard (1...9).contains(digits.count), let delimiter = after.first, ".)".contains(delimiter),
                  after.dropFirst().first == " " else { return nil }
            marker = digits + "."
            rest = after.dropFirst(2)
        }
        let text = rest.trimmingCharacters(in: .whitespaces)
        if marker == "•" {
            for (box, symbol) in [("[ ] ", "☐"), ("[x] ", "☑"), ("[X] ", "☑")] where text.hasPrefix(box) {
                return (symbol, indent, String(text.dropFirst(box.count)))
            }
        }
        return (marker, indent, text)
    }

    /// Leading indentation in columns, a tab counting as four.
    private static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 } else if character == "\t" { count += 4 } else { break }
        }
        return count
    }
}
