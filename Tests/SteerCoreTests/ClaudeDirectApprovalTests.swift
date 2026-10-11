import Foundation
import Testing
@testable import SteerCore

// Shapes observed on Claude Code 2.1.296 in docs/evidence/claude-file-approvals.md.

@Test func claudeFileRequestsWithTheProvenShapeAreDecidable() throws {
    let edit = try #require(ClaudeDirectApproval.details(toolName: "Edit", toolInput: [
        "file_path": "/tmp/lab/target.txt", "old_string": "alpha", "new_string": "beta", "replace_all": false]))
    #expect(edit.action == "Edit file")
    #expect(edit.command == "/tmp/lab/target.txt")
    #expect(edit.commandLabel == "path")
    #expect(edit.longText == "Replace:\nalpha\n\nWith:\nbeta")

    let everywhere = try #require(ClaudeDirectApproval.details(toolName: "Edit", toolInput: [
        "file_path": "/tmp/a", "old_string": "x", "new_string": "", "replace_all": true]))
    #expect(everywhere.longText == "Replace every occurrence of:\nx\n\nWith:\n(empty)")

    let write = try #require(ClaudeDirectApproval.details(toolName: "Write", toolInput: [
        "file_path": "/tmp/lab/created.txt", "content": "lab ."]))
    #expect(write.action == "Write file")
    #expect(write.longText == "Content (5 characters):\nlab .")

    let replace = try #require(ClaudeDirectApproval.details(toolName: "NotebookEdit", toolInput: [
        "notebook_path": "/tmp/nb.ipynb", "cell_id": "c1", "new_source": "print(2)", "edit_mode": "replace"]))
    #expect(replace.action == "Edit notebook")
    #expect(replace.longText == "Replace the source of cell c1:\nprint(2)")
    let insert = try #require(ClaudeDirectApproval.details(toolName: "NotebookEdit", toolInput: [
        "notebook_path": "/tmp/nb.ipynb", "cell_id": "c1", "new_source": "print(3)", "cell_type": "code",
        "edit_mode": "insert"]))
    #expect(insert.longText == "Insert a new code cell after cell c1:\nprint(3)")
    let delete = try #require(ClaudeDirectApproval.details(toolName: "NotebookEdit", toolInput: [
        "notebook_path": "/tmp/nb.ipynb", "cell_id": "c1", "new_source": "", "edit_mode": "delete"]))
    #expect(delete.longText == "Delete cell c1")

    let read = try #require(ClaudeDirectApproval.details(toolName: "Read", toolInput: ["file_path": "/tmp/outside.txt"]))
    #expect(read.action == "Read file")
    #expect(read.longText == nil)
    let range = try #require(ClaudeDirectApproval.details(toolName: "Read", toolInput: [
        "file_path": "/tmp/outside.txt", "offset": 1, "limit": 1]))
    #expect(range.longText == "Lines: offset 1, limit 1")
}

@Test func claudeFileRequestsOutsideTheProvenShapeStayNative() {
    let rejected: [(String, [String: Any])] = [
        // An unobserved extra key, even one the schema might allow later.
        ("Edit", ["file_path": "/tmp/a", "old_string": "x", "new_string": "y", "replace_all": false, "extra": "z"]),
        // A missing required key.
        ("Edit", ["file_path": "/tmp/a", "old_string": "x"]),
        // A number where Claude sends a JSON boolean.
        ("Edit", ["file_path": "/tmp/a", "old_string": "x", "new_string": "y", "replace_all": NSNumber(value: 1)]),
        // A relative path, or one with a control character.
        ("Write", ["file_path": "target.txt", "content": "x"]),
        ("Write", ["file_path": "/tmp/a\nb", "content": "x"]),
        ("Write", ["file_path": "/tmp/a", "content": 5]),
        // replace_all is optional in Claude's schema, but every observed Edit carried it.
        ("Edit", ["file_path": "/tmp/a", "old_string": "x", "new_string": "y"]),
        // Leading/trailing whitespace a display could trim, or a bidirectional override that reorders the shown path.
        ("Write", ["file_path": "/tmp/a ", "content": "x"]),
        ("Write", ["file_path": "/tmp/\u{202E}txt.exe", "content": "x"]),
        ("Write", ["file_path": "/tmp/a\u{2028}b", "content": "x"]),
        ("Write", ["file_path": "/tmp/a\u{2029}b", "content": "x"]),
        ("NotebookEdit", ["notebook_path": "/tmp/nb.ipynb", "cell_id": "c\u{2028}1", "new_source": "x", "edit_mode": "replace"]),
        ("NotebookEdit", ["notebook_path": "/tmp/nb.ipynb", "cell_id": "c1", "new_source": "", "edit_mode": "move"]),
        ("NotebookEdit", ["notebook_path": "/tmp/nb.ipynb", "new_source": "x", "edit_mode": "replace"]),
        ("NotebookEdit", ["notebook_path": "/tmp/nb.ipynb", "cell_id": "c1", "new_source": "x", "cell_type": "code",
                          "edit_mode": "replace"]),
        // Only code-cell inserts after an existing cell, and deletes with empty source, were observed.
        ("NotebookEdit", ["notebook_path": "/tmp/nb.ipynb", "new_source": "x", "cell_type": "code", "edit_mode": "insert"]),
        ("NotebookEdit", ["notebook_path": "/tmp/nb.ipynb", "cell_id": "c1", "new_source": "x", "edit_mode": "insert",
                          "cell_type": "markdown"]),
        ("NotebookEdit", ["notebook_path": "/tmp/nb.ipynb", "cell_id": "c1", "new_source": "x", "edit_mode": "delete"]),
        ("Read", ["file_path": "/tmp/a", "offset": 1]),
        ("Read", ["file_path": "/tmp/a", "offset": -1, "limit": 1]),
        ("Read", ["file_path": "/tmp/a", "offset": 1, "limit": 1.5]),
        ("Read", ["file_path": "/tmp/a", "pages": "1-2"]),
        // Tools that raised no PermissionRequest, or were never proven.
        ("Grep", ["pattern": "x", "path": "/tmp"]),
        ("Glob", ["pattern": "*.txt", "path": "/tmp"]),
        ("LSP", ["file_path": "/tmp/a"]),
    ]
    for (tool, input) in rejected {
        #expect(ClaudeDirectApproval.details(toolName: tool, toolInput: input) == nil, "\(tool) \(input)")
        #expect(ClaudeDirectApproval.accepts(toolName: tool, toolInput: input) == false, "\(tool) \(input)")
    }
    // Bash stays decidable by name alone, exactly as before the file family.
    #expect(ClaudeDirectApproval.accepts(toolName: "Bash", toolInput: [:]))
}

@Test func claudeFilePreviewIsBoundedLabeledAndInert() throws {
    let long = String(repeating: "a", count: ClaudeDirectApproval.maximumPreview + 10)
    let write = try #require(ClaudeDirectApproval.details(toolName: "Write", toolInput: ["file_path": "/tmp/a", "content": long]))
    let text = try #require(write.longText)
    #expect(text.hasPrefix("Content (\(long.count) characters):\n"))
    #expect(text.hasSuffix("… shortened; \(long.count) characters in all. The full text is in Claude."))
    #expect(text.count < long.count + 120)

    // Characters a terminal could act on never reach the notch.
    let edit = try #require(ClaudeDirectApproval.details(toolName: "Edit", toolInput: [
        "file_path": "/tmp/a", "old_string": "a\u{1b}[2Jb", "new_string": "\u{7}", "replace_all": false]))
    #expect(edit.longText?.contains("\u{1b}") == false)
    #expect(edit.longText?.contains("\u{7}") == false)
}

@Test func claudeFileRequestTargetsTheCallsPath() {
    #expect(ClaudeDirectApproval.target(toolName: "Edit", toolInput: ["file_path": "/a"]) == "/a")
    #expect(ClaudeDirectApproval.target(toolName: "NotebookEdit", toolInput: ["notebook_path": "/nb"]) == "/nb")
    #expect(ClaudeDirectApproval.target(toolName: "Bash", toolInput: ["command": "ls"]) == nil)
}

// Shapes observed in docs/evidence/claude-web-approvals.md.

@Test func claudeWebRequestsWithTheProvenShapeAreDecidable() throws {
    let fetch = try #require(ClaudeDirectApproval.details(toolName: "WebFetch", toolInput: [
        "url": "https://example.com/", "prompt": "What is the title of this page?"]))
    #expect(fetch.action == "Fetch web page")
    #expect(fetch.command == "https://example.com/")
    #expect(fetch.commandLabel == "url")
    #expect(fetch.longText == "Host: example.com\n\nClaude asks of the page:\nWhat is the title of this page?")
    // A redirect target arrives as its own request; the redirecting URL is shown exactly as given.
    let redirect = try #require(ClaudeDirectApproval.details(toolName: "WebFetch", toolInput: [
        "url": "https://httpbin.org/redirect-to?url=https%3A%2F%2Fexample.com%2F", "prompt": "title"]))
    #expect(redirect.longText?.hasPrefix("Host: httpbin.org\n") == true)
    // Punycode stays as written, never decoded into lookalike characters.
    let punycode = try #require(ClaudeDirectApproval.details(toolName: "WebFetch", toolInput: [
        "url": "https://xn--e1aybc.com/path?q=1#top", "prompt": "t"]))
    #expect(punycode.longText?.hasPrefix("Host: xn--e1aybc.com\n") == true)

    let search = try #require(ClaudeDirectApproval.details(toolName: "WebSearch", toolInput: [
        "query": "example domain", "mode": "standard"]))
    #expect(search.action == "Search the web")
    #expect(search.command == "example domain")
    #expect(search.commandLabel == "query")
    #expect(search.longText == nil)
    #expect(ClaudeDirectApproval.target(toolName: "WebFetch", toolInput: ["url": "https://example.com/"]) == "https://example.com/")
    #expect(ClaudeDirectApproval.target(toolName: "WebSearch", toolInput: ["query": "q"]) == "q")
}

@Test func claudeWebRequestsOutsideTheProvenShapeStayNative() {
    let rejected: [(String, [String: Any])] = [
        ("WebFetch", ["url": "https://example.com/"]),
        ("WebFetch", ["url": "https://example.com/", "prompt": "t", "extra": "x"]),
        ("WebFetch", ["url": "example.com", "prompt": "t"]),
        ("WebFetch", ["url": "file:///etc/hosts", "prompt": "t"]),
        ("WebFetch", ["url": "ftp://example.com/", "prompt": "t"]),
        // Only https was observed.
        ("WebFetch", ["url": "http://example.com/", "prompt": "t"]),
        // Forms where Claude's WHATWG parser and Foundation name different hosts, or the host could be disguised.
        ("WebFetch", ["url": "https://evil.com\\@example.com/", "prompt": "t"]),
        ("WebFetch", ["url": "https://example.com@evil.com/", "prompt": "t"]),
        ("WebFetch", ["url": "https://user:pass@example.com/", "prompt": "t"]),
        ("WebFetch", ["url": "https://example.com:8443/", "prompt": "t"]),
        ("WebFetch", ["url": "https://exa%6Dple.com/", "prompt": "t"]),
        ("WebFetch", ["url": "https://тест.com/", "prompt": "t"]),
        ("WebFetch", ["url": "https://example.com/caf\u{00E9}", "prompt": "t"]),
        ("WebFetch", ["url": "https:///path", "prompt": "t"]),
        ("WebFetch", ["url": "https://.example.com/", "prompt": "t"]),
        ("WebFetch", ["url": "https://example.com/a b", "prompt": "t"]),
        ("WebFetch", ["url": "https://exa\u{202E}mple.com/", "prompt": "t"]),
        ("WebFetch", ["url": "https://example.com/", "prompt": 3]),
        ("WebSearch", ["query": "example domain"]),
        ("WebSearch", ["query": "example domain", "mode": "extended"]),
        ("WebSearch", ["query": "", "mode": "standard"]),
        ("WebSearch", ["query": "two\nlines", "mode": "standard"]),
        ("WebSearch", ["query": " padded", "mode": "standard"]),
        ("WebSearch", ["query": String(repeating: "q", count: ClaudeDirectApproval.maximumQuery + 1), "mode": "standard"]),
        // One character but thousands of bytes: bounded by bytes so the helper keeps the matching PreToolUse value.
        ("WebSearch", ["query": "e" + String(repeating: "\u{0301}", count: 3000), "mode": "standard"]),
        // Excluded families.
        ("ExitPlanMode", ["plan": "do it", "planFilePath": "/tmp/plan.md"]),
        ("mcp__steer-lab__lab_echo", ["text": "hello"]),
    ]
    for (tool, input) in rejected {
        #expect(ClaudeDirectApproval.accepts(toolName: tool, toolInput: input) == false, "\(tool) \(input)")
    }
}

@Test func claudeDirectApprovalRechecksACommandByItsLabel() {
    #expect(ClaudeDirectApproval.validCommand("/tmp/a", label: "path"))
    #expect(ClaudeDirectApproval.validCommand("https://example.com/", label: "url"))
    #expect(ClaudeDirectApproval.validCommand("example domain", label: "query"))
    #expect(ClaudeDirectApproval.validCommand("https://example.com/", label: "path") == false)
    #expect(ClaudeDirectApproval.validCommand("/tmp/a", label: "url") == false)
    #expect(ClaudeDirectApproval.validCommand("/tmp/a", label: nil) == false)
    #expect(ClaudeDirectApproval.validCommand("/tmp/a", label: "command") == false)
}
