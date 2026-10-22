import HerdlyCore
import Testing

@Test func aMarkdownTableBecomesHeaderAndRows() {
    let source = """
    Rotate in this order, across **Production and Dev**:

    | Priority | Secrets | Why |
    |---|:---:|---|
    | **1 — Database access** | PostgreSQL password / `DATABASE_URL` | Could expose customer data. |
    | **2 — Login** | `A_SECRET`, `B\\|C` | Impersonation |
    """
    #expect(MessageMarkdown.blocks(source) == [
        .paragraph("Rotate in this order, across **Production and Dev**:"),
        .table(header: ["Priority", "Secrets", "Why"], rows: [
            ["**1 — Database access**", "PostgreSQL password / `DATABASE_URL`", "Could expose customer data."],
            ["**2 — Login**", "`A_SECRET`, `B|C`", "Impersonation"],
        ]),
    ])
}

@Test func aTableCutMidRowStillHasEveryColumn() {
    let source = "a | b | c\n--- | --- | ---\n1 | 2 | 3\n| 4 | 5…"
    #expect(MessageMarkdown.blocks(source) == [
        .table(header: ["a", "b", "c"], rows: [["1", "2", "3"], ["4", "5…", ""]]),
    ])
}

@Test func pipesWithoutASeparatorRowStayText() {
    #expect(MessageMarkdown.blocks("Run `a | b` then\nx | y") == [.paragraph("Run `a | b` then\nx | y")])
}

@Test func headingsListsQuotesRulesAndCode() {
    let source = """
    ## Summary ##
    - First
      continues here
      - Nested
    2) Second
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
    #expect(MessageMarkdown.blocks(source) == [
        .heading(level: 2, text: "Summary"),
        .listItem(marker: "•", depth: 0, text: "First\ncontinues here"),
        .listItem(marker: "•", depth: 1, text: "Nested"),
        .listItem(marker: "2.", depth: 0, text: "Second"),
        .listItem(marker: "☑", depth: 0, text: "Done"),
        .listItem(marker: "☐", depth: 0, text: "Todo"),
        .quote("Quoted\ntwice"),
        .rule,
        .code("    let x = 1"),
        .paragraph("#notAHeading"),
    ])
}

@Test func anUnclosedFenceRunsToTheEnd() {
    #expect(MessageMarkdown.blocks("Fix:\n```\nmake test\n# not a heading") == [
        .paragraph("Fix:"), .code("make test\n# not a heading"),
    ])
}

@Test func emphasisIsNotARuleOrList() {
    #expect(MessageMarkdown.blocks("**Bold** line\n*italic*") == [.paragraph("**Bold** line\n*italic*")])
}

@Test func thePreviewKeepsIndentationForCodeAndNestedLists() {
    let preview = CompletionPreview("\n  \n  - a\n    - b   \n\n")
    #expect(preview?.text == "- a\n  - b")
    #expect(preview?.extent == .whole)
}
