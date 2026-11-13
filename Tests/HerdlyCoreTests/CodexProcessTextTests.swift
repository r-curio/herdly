import Foundation
import Testing
@testable import HerdlyCore

/// Both readings of a listing, which must agree: as bytes where a line is ASCII, and by character.
private func expectSameReading(_ list: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let arguments = CodexCLIProcesses.arguments(processList: list)
    #expect(arguments == CodexCLIProcesses.argumentsByCharacter(processList: list), "arguments of \(list.debugDescription)",
            sourceLocation: sourceLocation)
    for text in [list, arguments] {
        #expect(CodexCLIProcesses.isRunning(processList: text) == CodexCLIProcesses.isRunningByCharacter(processList: text),
                "isRunning of \(text.debugDescription)", sourceLocation: sourceLocation)
    }
}

@Test func codexProcessRulesHoldForEveryShapeOfLine() {
    func running(_ arguments: String) -> Bool { CodexCLIProcesses.isRunning(processList: arguments) }
    #expect(running("node /opt/homebrew/bin/codex.js --model gpt-5"))
    #expect(running("/opt/homebrew/bin/codex-aarch64-apple-darwin"))
    #expect(running("  codex  resume"))
    #expect(running("zsh\n/usr/local/bin/codex/\nvim"))
    #expect(running("/usr/local/bin//codex// --flag"))
    #expect(!running(""))
    #expect(!running("\n\n   \n"))
    #expect(!running("/Applications/Codex.app/Contents/Resources/codex app-server --listen stdio://"))
    #expect(running("codex --name app-server2"))
    #expect(!running("node run codex"))
    #expect(!running("xcodex\ncodexs\ncodex.jsx\n/ /"))
    #expect(running("/Users/me/Bibliothèque/codex --répertoire été"))
    #expect(!running("/Users/me/Bibliothèque/codex app-server --répertoire été"))

    func arguments(_ list: String) -> String { CodexCLIProcesses.arguments(processList: list) }
    #expect(arguments("  101 codex resume\n20202 /bin/zsh -l\n") == "codex resume\n/bin/zsh -l")
    #expect(arguments("101   spaced   out") == "spaced   out")
    #expect(arguments("no pid here\n   \n+7 signed\n99999999999 too large\n12") == "no pid here\n\nsigned\n99999999999 too large\n12")
    #expect(arguments("  303 /Users/me/été/outil --drapeau") == "/Users/me/été/outil --drapeau")
}

@Test func codexProcessListingReadAsBytesEqualsTheListingReadByCharacter() {
    expectSameReading(syntheticProcessList(count: 600))
    expectSameReading(syntheticProcessList(count: 600).replacingOccurrences(of: "codex", with: "kodex"))
    let lines = [
        "", " ", "   ", "101 codex", "  101 codex resume", "101", "101 ", " 101  ", "+12 codex", "-3 codex", "99999999999 codex",
        "1a codex", "codex", "codex/", "/", "//", "a//codex//", "node codex.js", "node /x/codex.js app-server", "a b codex",
        "codex-", "codex-x", "codex.j", "app-server", "codex app-server", "codex app-server2", "codex x/app-server",
        // A carriage return joins the newline after it into one character, which ends no line.
        "101 codex\r", "\r", "codex\rapp-server",
        // A combining mark makes the character before it another character: not a space, slash, digit or name.
        "101\u{301} codex", "101 \u{301}codex", "101 codex\u{301}", "codex \u{301}app-server", "/bin/\u{301}codex", "/bin/codex/\u{301}",
        "codex app-server\u{301}", "\u{301}", " \u{301}", "é codex", "codex é", "codex 👩‍👩‍👧 app-server", "1\u{200D}2 codex", "１２ codex",
        "101\tcodex", "\tcodex",
    ]
    for line in lines {
        expectSameReading(line)
        expectSameReading(line + "\n")
        expectSameReading("7 zsh\n" + line + "\n8 vim")
    }
    // Every pairing, so each line is read beside every kind of neighbour.
    for first in lines { for second in lines { expectSameReading(first + "\n" + second) } }

    // The same pieces in a fixed pseudo-random order.
    let pieces = [" ", " ", "\n", "\n", "/", "codex", "codex.js", "codex-", "app-server", "1", "23", "+", "-", "x", "\r", "\u{301}", "é", "\u{200D}", "\t"]
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
    for _ in 0..<5_000 {
        expectSameReading((0..<next(24)).map { _ in pieces[next(pieces.count)] }.joined())
    }
}
