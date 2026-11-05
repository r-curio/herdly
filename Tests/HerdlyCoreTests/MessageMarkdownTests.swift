import Foundation
import HerdlyCore
import Testing

/// One line per block, indented by nesting, so a test reads as the structure it expects.
private func outline(_ blocks: [MessageMarkdownBlock], indent: String = "") -> [String] {
    blocks.flatMap { block -> [String] in
        switch block {
        case let .paragraph(text): return [indent + "p " + String(text.characters)]
        case let .heading(level, text): return [indent + "h\(level) " + String(text.characters)]
        case let .code(text): return [indent + "code " + text]
        case .rule: return [indent + "rule"]
        case let .quote(blocks): return [indent + "quote"] + outline(blocks, indent: indent + "  ")
        case let .list(items):
            return items.flatMap { [indent + "item " + $0.marker] + outline($0.blocks, indent: indent + "  ") }
        case let .table(_, header, rows):
            return ([header] + rows).map { indent + "row " + $0.map { String($0.characters) }.joined(separator: " | ") }
        }
    }
}

private func parsed(_ source: String) -> [String] { outline(MessageMarkdown.blocks(source)) }

private func inlineIntents(_ source: String) -> [String: InlinePresentationIntent] {
    guard case let .paragraph(text)? = MessageMarkdown.blocks(source).first else { return [:] }
    var result: [String: InlinePresentationIntent] = [:]
    for (intent, range) in text.runs[\.inlinePresentationIntent] {
        if let intent { result[String(text[range].characters)] = intent }
    }
    return result
}

@Test func aMarkdownTableBecomesHeaderAndRows() {
    let source = """
    Rotate in this order, across **Production and Dev**:

    | Priority | Secrets | Why |
    |---|:---:|---:|
    | **1 — Database access** | PostgreSQL password / `DATABASE_URL` | Could expose customer data. |
    | **2 — Login** | `A_SECRET`, `B\\|C` | Impersonation |
    """
    #expect(parsed(source) == [
        "p Rotate in this order, across Production and Dev:",
        "row Priority | Secrets | Why",
        "row 1 — Database access | PostgreSQL password / DATABASE_URL | Could expose customer data.",
        "row 2 — Login | A_SECRET, B|C | Impersonation",
    ])
    guard case let .table(alignments, _, _) = MessageMarkdown.blocks(source)[1] else {
        Issue.record("expected a table"); return
    }
    #expect(alignments == [.left, .center, .right])
}

@Test func aTableCutMidRowStillHasEveryColumn() {
    #expect(parsed("a | b | c\n--- | --- | ---\n1 | 2 | 3\n| 4 | 5…") == [
        "row a | b | c", "row 1 | 2 | 3", "row 4 | 5… | ",
    ])
    // An empty cell holds its own column, not the next cell's.
    #expect(parsed("a | b | c\n--- | --- | ---\n|  | 2 |  |") == ["row a | b | c", "row  | 2 | "])
}

@Test func pipesWithoutASeparatorRowStayText() {
    #expect(parsed("Run `a | b` then\nx | y") == ["p Run a | b then\nx | y"])
}

@Test func headingsListsQuotesRulesAndCode() {
    let source = """
    ## Summary ##
    - First
      continues here
      - Nested
    - [x] Done
    - [ ] Todo

    > Quoted
    > twice

    ---
    ```swift
        let x = 1
    ```
    #notAHeading
    """
    #expect(parsed(source) == [
        "h2 Summary",
        "item •", "  p First\ncontinues here", "  item •", "    p Nested",
        "item ☑", "  p Done",
        "item ☐", "  p Todo",
        "quote", "  p Quoted\ntwice",
        "rule",
        "code     let x = 1",
        "p #notAHeading",
    ])
}

@Test func underlinedHeadingsAreHeadingsNotRules() {
    #expect(parsed("Title\n=====\n\nSub\n---\nbody") == ["h1 Title", "h2 Sub", "p body"])
}

@Test func anItemKeepsItsLaterParagraphsAndCode() {
    let source = """
    1. First

       Still first

       ```sh
       make test
       ```
    2. Second
    """
    #expect(parsed(source) == [
        "item 1.", "  p First", "  p Still first", "  code make test",
        "item 2.", "  p Second",
    ])
}

@Test func anOrderedListKeepsItsSourceNumbersAcrossABreak() {
    #expect(parsed("1. one\n\n```\ncode\n```\n\n2. two\n3) three") == [
        "item 1.", "  p one", "code code", "item 2.", "  p two", "item 3.", "  p three",
    ])
}

@Test func aQuoteHoldsItsOwnBlocks() {
    #expect(parsed("> **b**\n> - in quote\n>\n> ```\n> code\n> ```") == [
        "quote", "  p b", "  item •", "    p in quote", "  code code",
    ])
}

@Test func aLongerFenceHoldsAShorterOne() {
    #expect(parsed("````md\n```swift\ninner\n```\n````\nafter") == ["code ```swift\ninner\n```", "p after"])
}

@Test func anIndentedBlockIsCode() {
    #expect(parsed("para\n\n    let x = 1") == ["p para", "code let x = 1"])
}

@Test func codeKeepsItsTextExactly() {
    #expect(parsed("```\n**not bold**\n\n  | a |\n```") == ["code **not bold**\n\n  | a |"])
}

@Test func anUnclosedFenceRunsToTheEnd() {
    #expect(parsed("Fix:\n```\nmake test\n# not a heading") == ["p Fix:", "code make test\n# not a heading"])
}

@Test func emphasisIsNotARuleOrList() {
    #expect(parsed("**Bold** line\n*italic*") == ["p Bold line\nitalic"])
}

@Test func inlineMarksSurviveForTheAppToStyle() {
    let intents = inlineIntents("**b** *i* `c` ~~s~~")
    #expect(intents["b"] == .stronglyEmphasized)
    #expect(intents["i"] == .emphasized)
    #expect(intents["c"] == .code)
    #expect(intents["s"] == .strikethrough)
}

@Test func aReferenceLinkResolvesAcrossBlocks() throws {
    guard case let .paragraph(text)? = MessageMarkdown.blocks("See [the docs][1].\n\n[1]: https://example.com/a").first else {
        Issue.record("expected a paragraph"); return
    }
    #expect(String(text.characters) == "See the docs.")
    #expect(text.runs.compactMap(\.link) == [try #require(URL(string: "https://example.com/a"))])
}

@Test func noTextDisappears() {
    // Generics, block HTML, and an unclosed mark all read as typed.
    #expect(parsed("Array<Int> and a<br>b") == ["p Array<Int> and a<br>b"])
    #expect(parsed("<details>\n<summary>More</summary>\nbody\n</details>") == [
        "p <details>\n<summary>More</summary>\nbody\n</details>",
    ])
    #expect(parsed("**cut bold and `code") == ["p **cut bold and `code"])
    #expect(parsed("rm *.log and *.tmp") == ["p rm *.log and *.tmp"])
}

@Test func emptyInputHasNoBlocks() {
    #expect(MessageMarkdown.blocks("").isEmpty)
    #expect(MessageMarkdown.blocks(" \n ").isEmpty)
}

@Test func absurdNestingFlattensInsteadOfRecursing() {
    let quotes = MessageMarkdown.blocks(String(repeating: ">", count: 20_000) + " deep")
    #expect(outline(quotes).last?.hasSuffix("p deep") == true)
    #expect(outline(quotes).count <= 18)

    let lists = (0..<400).map { String(repeating: " ", count: $0 * 2) + "- x\($0)" }.joined(separator: "\n")
    let text = outline(MessageMarkdown.blocks(lists)).joined(separator: "\n")
    #expect(text.contains("x0"))
    #expect(text.contains("x399"))
}

@Test func firstLineReadsThroughTheMarkdown() {
    func first(_ source: String) -> String { String(MessageMarkdown.firstLine(source, limit: 56).line.characters) }
    #expect(first("## Summary\nbody") == "Summary")
    #expect(first("- item one\n- item two") == "item one")
    #expect(first("> quoted") == "quoted")
    #expect(first("---\n\nafter") == "after")
    #expect(first("| a | b |\n|---|---|\n| 1 | 2 |") == "a · b")
    #expect(first("```swift\n\n  let x = 1\n```") == "let x = 1")
}

@Test func aCutFirstLineNeverStrandsAMark() {
    let (line, isWhole) = MessageMarkdown.firstLine("**" + String(repeating: "word ", count: 30) + "end**", limit: 56)
    let text = String(line.characters)
    #expect(text.count <= 56)
    #expect(text.hasSuffix("…"))
    #expect(!text.contains("*"))
    #expect(!isWhole)
    // The part that is left stays bold.
    #expect(line.runs[\.inlinePresentationIntent].contains { $0.0 == .stronglyEmphasized })
}

@Test func firstLineKnowsWhenItIsTheWholeMessage() {
    #expect(MessageMarkdown.firstLine("**Done** in `a.swift`", limit: 56).isWhole)
    #expect(MessageMarkdown.firstLine("# Title", limit: 56).isWhole)
    #expect(!MessageMarkdown.firstLine("One\nTwo", limit: 56).isWhole)
    #expect(!MessageMarkdown.firstLine("```\nx\n```", limit: 56).isWhole)
}

@Test func thePreviewKeepsIndentationForCodeAndNestedLists() {
    let preview = CompletionPreview("\n  \n  - a\n    - b   \n\n")
    #expect(preview?.text == "- a\n  - b")
    #expect(preview?.extent == .whole)
}
