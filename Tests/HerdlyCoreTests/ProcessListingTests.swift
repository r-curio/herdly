import Foundation
import Testing
@testable import HerdlyCore

// #303: process listings come from the kernel instead of `/bin/ps`. HerdlyApp reads the records;
// `ProcessListing` writes them in the exact text shapes `ps` printed, so the existing parsers and their
// identity rules stay unchanged. The fixtures are `ps` output captured on macOS 26.

private func record(_ pid: Int32, ppid: Int32 = 1, uid: UInt32 = 503, tty: String? = nil, state: ProcessRunState = .sleeping,
                    leader: Bool = false, foreground: Bool = false, name: String, arguments: [String]?) -> KernelProcessRecord {
    KernelProcessRecord(pid: pid, ppid: ppid, uid: uid, tty: tty, state: state, sessionLeader: leader,
                        foreground: foreground, shortName: name, arguments: arguments)
}

private let launchd = record(1, ppid: 0, uid: 0, name: "launchd", arguments: ["/sbin/launchd"])
private let agent = record(359, uid: 0, name: "UserEventAgent", arguments: ["/usr/libexec/UserEventAgent", "(System)"])
private let renderer = record(277, ppid: 18480, name: "Paper Helper (Re",
                              arguments: ["/Applications/Paper.app/Contents/MacOS/Paper Helper (Renderer)", "--type=renderer"])
private let login = record(17717, ppid: 17676, uid: 0, tty: "ttys000", name: "login", arguments: ["/usr/bin/login"])
private let loginShell = record(17726, ppid: 17717, tty: "ttys000", leader: true, name: "zsh", arguments: ["-/bin/zsh"])
private let shell = record(93413, ppid: 93412, tty: "ttys001", leader: true, name: "zsh", arguments: ["-zsh"])
private let retitled = record(27168, ppid: 27165, tty: "ttys001", foreground: true, name: "node",
                              arguments: ["npm run dev --port 3010"])
private let codex = record(27200, ppid: 93413, tty: "ttys001", state: .running, foreground: true, name: "codex",
                           arguments: ["/opt/homebrew/bin/codex", "--model", "o3"])
private let unreadable = record(400, uid: 0, name: "securityd", arguments: nil)

@Test func pidArgsMatchesPSWithArgumentsJoinedAndUnreadableOnesInParentheses() {
    let output = ProcessListing.pidArgs([renderer, launchd, agent, unreadable])
    #expect(output == """
        \u{20}   1 /sbin/launchd
        \u{20} 277 /Applications/Paper.app/Contents/MacOS/Paper Helper (Renderer) --type=renderer
        \u{20} 359 /usr/libexec/UserEventAgent (System)
        \u{20} 400 (securityd)

        """)
}

@Test func pidArgsFeedsTheCodexProcessRulesExactlyAsPSDid() {
    let fixture = """
        \u{20}   1 /sbin/launchd
        17726 -/bin/zsh
        27200 /opt/homebrew/bin/codex --model o3
        27300 /Applications/Codex.app/Contents/Resources/codex app-server

        """
    let desktop = record(27300, name: "codex", arguments: ["/Applications/Codex.app/Contents/Resources/codex", "app-server"])
    let formatted = ProcessListing.pidArgs([launchd, loginShell, codex, desktop])
    #expect(formatted == fixture)
    #expect(CodexCLIProcesses.candidatePIDs(processList: formatted) == [27200])
    #expect(CodexCLIProcesses.isRunning(processList: CodexCLIProcesses.arguments(processList: formatted)))
}

@Test func anArgumentCannotForgeAnotherRowOrColumn() {
    // `ps` escapes tabs and newlines as octal and other control characters in caret form.
    let forged = record(500, name: "sh", arguments: ["sh", "-c", "x\n27201 codex\tq\u{1}\u{7f}é"])
    let output = ProcessListing.pidArgs([forged])
    #expect(output == "  500 sh -c x\\01227201 codex\\011q^A^?é\n")
    #expect(CodexCLIProcesses.candidatePIDs(processList: output) == [500])
    #expect(ProcessListing.visible("\u{80}a") == "M^@a")
}

@Test func tableShapeMatchesPSAndParsesToTheSameZellijTable() throws {
    let fixture = """
        \u{20}   1     0     0 ??       /sbin/launchd
        \u{20} 277 18480   503 ??       /Applications/Paper.app/Contents/MacOS/Paper Helper (Renderer)
        \u{20} 400     1     0 ??       securityd
        17717 17676     0 ttys000  /usr/bin/login
        17726 17717   503 ttys000  -/bin/zsh
        27168 27165   503 ttys001  npm run dev --port 3010

        """
    let formatted = ProcessListing.pidPPIDUIDTTYComm([launchd, renderer, login, loginShell, retitled, unreadable])
    #expect(formatted == fixture)
    let fromPS = try #require(ZellijProcessTable.parse(fixture, owner: 503, arguments: [:], startTimes: [:]))
    #expect(ZellijProcessTable.parse(formatted, owner: 503, arguments: [:], startTimes: [:]) == fromPS)
}

@Test func ttyShapeMatchesPSWithTheForegroundFlag() throws {
    let fixture = """
        27168 S+   npm run dev --port 3010
        27200 R+   /opt/homebrew/bin/codex
        93413 Ss   -zsh

        """
    let formatted = ProcessListing.pidStatComm([codex, shell, login, retitled], tty: "ttys001")
    #expect(formatted == fixture)
    let parsed = try #require(TerminalForegroundProcesses.parse(formatted))
    #expect(parsed == TerminalForegroundProcesses.parse(fixture))
    #expect(parsed.map(\.name) == ["npm run dev --port 3010", "codex", "-zsh"])
    #expect(parsed.map(\.foreground) == [true, true, false])
    // No process on the tty is an empty read, as `ps -t` printed nothing.
    #expect(ProcessListing.pidStatComm([launchd], tty: "ttys009") == "")
}

@Test func stateLettersFollowPS() {
    #expect(ProcessListing.stat(record(1, state: .stopped, name: "x", arguments: nil)) == "T")
    #expect(ProcessListing.stat(record(1, state: .zombie, name: "x", arguments: nil)) == "Z")
    #expect(ProcessListing.stat(record(1, state: .running, leader: true, foreground: true, name: "x", arguments: nil)) == "Rs+")
}

@Test func parentShapeFeedsTheDescendantWalk() {
    let formatted = ProcessListing.pidPPID([launchd, login, loginShell])
    #expect(formatted == "    1     0\n17717 17676\n17726 17717\n")
}

@Test func anEmptyFirstArgumentFallsBackToTheShortName() {
    // An empty name would make the whole `ps -t` read malformed.
    let blank = record(600, tty: "ttys001", name: "python3", arguments: [""])
    #expect(ProcessListing.command(blank) == "python3")
}

// MARK: - KERN_PROCARGS2

private func procargs(count: Int32, _ strings: [String], padding: Int = 3) -> [UInt8] {
    var bytes = withUnsafeBytes(of: count) { Array($0) }
    bytes += Array(strings[0].utf8) + Array(repeating: 0, count: padding)
    for value in strings.dropFirst() { bytes += Array(value.utf8) + [0] }
    return bytes
}

@Test func procargsYieldTheArgumentVectorWithoutTheEnvironment() {
    let bytes = procargs(count: 2, ["/opt/homebrew/bin/zellij", "zellij", "--server", "HOME=/Users/x"])
    #expect(KernelProcessArguments.parse(bytes) == ["zellij", "--server"])
}

@Test func truncatedOrImplausibleProcargsAreUnreadable() {
    #expect(KernelProcessArguments.parse(procargs(count: 3, ["/bin/sh", "sh", "-c"])) == nil)
    #expect(KernelProcessArguments.parse(procargs(count: 0, ["/bin/sh", "sh"])) == nil)
    #expect(KernelProcessArguments.parse(procargs(count: 5000, ["/bin/sh", "sh"])) == nil)
    #expect(KernelProcessArguments.parse([1, 0]) == nil)
}

@Test func anotherUsersProcessShowsItsExecutablePath() {
    // `ps` reads root's `login` vector; Herdly reads only its executable path, which `ps`'s argv[0] is.
    let root = KernelProcessRecord(pid: 17717, ppid: 17676, uid: 0, tty: "ttys000", state: .running, sessionLeader: true,
                                   foreground: false, shortName: "login", arguments: nil, executablePath: "/usr/bin/login")
    #expect(ProcessListing.pidPPIDUIDTTYComm([root]) == "17717 17676     0 ttys000  /usr/bin/login\n")
    #expect(ProcessListing.pidArgs([root]) == "17717 /usr/bin/login\n")
}
