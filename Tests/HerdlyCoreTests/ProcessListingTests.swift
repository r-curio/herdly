import Foundation
import Testing
@testable import HerdlyCore

// #303: process listings come from the kernel instead of `/bin/ps`. HerdlyApp reads the records;
// `ProcessListing` writes them in the exact text shapes `ps` printed, so the existing parsers and their
// identity rules stay unchanged. Every fixture line is `ps` output captured on this project's macOS 26
// development Mac (2026-10-22); each record holds the facts the kernel gives for that process.

private let me: UInt32 = 503

private func record(_ pid: Int32, ppid: Int32, uid: UInt32 = me, tty: String? = nil, state: ProcessRunState = .sleeping,
                    leader: Bool = false, foreground: Bool = false, name: String, arguments: [String]?) -> KernelProcessRecord {
    KernelProcessRecord(pid: pid, ppid: ppid, uid: uid, tty: tty, state: state, sessionLeader: leader,
                        foreground: foreground, shortName: name, arguments: arguments)
}

private let codexHome = "/Users/rmaisog/.codex/packages/standalone/releases/0.163.0-aarch64-apple-darwin/bin/codex"
// Root's: the kernel gives Herdly no argument vector for another user's process.
private let launchd = record(1, ppid: 0, uid: 0, leader: true, name: "launchd", arguments: nil)
private let login = record(17717, ppid: 17676, uid: 0, tty: "ttys000", leader: true, name: "login", arguments: nil)
// The user's own.
private let ghostty = record(17676, ppid: 1, name: "ghostty", arguments: ["/Applications/Ghostty.app/Contents/MacOS/ghostty"])
private let loginShell = record(17726, ppid: 17717, tty: "ttys000", name: "zsh", arguments: ["-/bin/zsh"])
private let herdr = record(18421, ppid: 17726, tty: "ttys000", foreground: true, name: "herdr", arguments: ["herdr"])
private let herdrServer = record(18426, ppid: 18421, leader: true, name: "herdr", arguments: ["/Users/rmaisog/.local/bin/herdr", "server"])
private let codexCLI = record(41894, ppid: 40207, tty: "ttys027", foreground: true, name: "codex",
                              arguments: ["codex", "--sandbox", "danger-full-access", "--ask-for-approval", "never", "-m", "gpt-6-luna"])
private let codexInTmux = record(55928, ppid: 55925, tty: "ttys030", leader: true, foreground: true, name: "codex",
                                 arguments: ["/Users/rmaisog/.local/bin/codex", "--no-daemon", "-m", "gpt-6-luna", "-s", "read-only"])
private let sleeper = record(71757, ppid: 71755, name: "sleep", arguments: ["sleep", "720"])
private let appServer = record(97265, ppid: 1, leader: true, name: "codex",
                               arguments: [codexHome, "app-server", "daemon", "pid-update-loop"])
private let table = [launchd, ghostty, login, loginShell, herdr, herdrServer, codexCLI, codexInTmux, sleeper, appServer]

@Test func pidArgsMatchesPSForTheUsersOwnProcessesAndLeavesUnreadableOnesOut() {
    let fixture = """
        17676 /Applications/Ghostty.app/Contents/MacOS/ghostty
        17726 -/bin/zsh
        18421 herdr
        18426 /Users/rmaisog/.local/bin/herdr server
        41894 codex --sandbox danger-full-access --ask-for-approval never -m gpt-6-luna
        55928 /Users/rmaisog/.local/bin/codex --no-daemon -m gpt-6-luna -s read-only
        71757 sleep 720
        97265 \(codexHome) app-server daemon pid-update-loop

        """
    let formatted = ProcessListing.pidArgs(table, limit: 1 << 20)
    // `ps` also lists launchd and login with their arguments; Herdly cannot read them, so they are absent.
    #expect(formatted == fixture)
    #expect(CodexCLIProcesses.candidatePIDs(processList: formatted!) == [41894, 55928])
    #expect(CodexCLIProcesses.candidatePIDs(processList: formatted!) == CodexCLIProcesses.candidatePIDs(processList: fixture))
}

@Test func anotherUsersCodexWithUnreadableArgumentsNeverCountsAsACLI() throws {
    // Without its vector an app-server could not show `app-server`, so it is left out entirely.
    let theirs = record(30000, ppid: 1, uid: 501, name: "codex", arguments: nil)
    let listing = try #require(ProcessListing.pidArgs([theirs, sleeper], limit: 1 << 20))
    #expect(listing == "71757 sleep 720\n")
    #expect(CodexCLIProcesses.candidatePIDs(processList: listing).isEmpty)
    #expect(!CodexCLIProcesses.isRunning(processList: CodexCLIProcesses.arguments(processList: listing)))
}

@Test func aListingOverItsLimitIsUnreadable() {
    let rows = ProcessListing.pidArgs([sleeper], limit: 1 << 20)!
    #expect(ProcessListing.pidArgs([sleeper], limit: rows.utf8.count) == rows)
    #expect(ProcessListing.pidArgs([sleeper], limit: rows.utf8.count - 1) == nil)
    #expect(ProcessListing.pidArgs([sleeper, appServer], limit: rows.utf8.count) == nil)
}

@Test func anArgumentCannotForgeAnotherRowOrColumn() {
    // `ps` escapes tabs and newlines as octal and other control characters in caret form.
    let forged = record(500, ppid: 1, name: "sh", arguments: ["sh", "-c", "x\n27201 codex\tq\u{1}\u{7f}é"])
    let output = ProcessListing.pidArgs([forged], limit: 1 << 20)
    #expect(output == "  500 sh -c x\\01227201 codex\\011q^A^?é\n")
    #expect(CodexCLIProcesses.candidatePIDs(processList: output!) == [500])
    #expect(ProcessListing.visible("\u{80}a") == "M^@a")
}

@Test func tableShapeParsesToTheSameZellijTableAsPS() throws {
    let fixture = """
        \u{20}   1     0     0 ??       /sbin/launchd
        17676     1   503 ??       /Applications/Ghostty.app/Contents/MacOS/ghostty
        17717 17676     0 ttys000  /usr/bin/login
        17726 17717   503 ttys000  -/bin/zsh
        18421 17726   503 ttys000  herdr
        18426 18421   503 ??       /Users/rmaisog/.local/bin/herdr
        41894 40207   503 ttys027  codex
        55928 55925   503 ttys030  /Users/rmaisog/.local/bin/codex
        71757 71755   503 ??       sleep
        97265     1   503 ??       \(codexHome)

        """
    let formatted = ProcessListing.pidPPIDUIDTTYComm(table)
    // Root's rows carry the kernel's short name where `ps` shows the path; the basename is the same.
    let fixtureLines = fixture.split(separator: "\n"), formattedLines = formatted.split(separator: "\n")
    for (ps, ours) in zip(fixtureLines, formattedLines) where ps.contains("   503 ") {
        #expect(ps == ours)
    }
    #expect(formattedLines.contains("    1     0     0 ??       launchd"))
    let fromPS = try #require(ZellijProcessTable.parse(fixture, owner: me, arguments: [:], startTimes: [:]))
    #expect(ZellijProcessTable.parse(formatted, owner: me, arguments: [:], startTimes: [:]) == fromPS)
}

@Test func ttyShapeParsesAsPSDidWithTheForegroundFlag() throws {
    let fixture = """
        17717 Ss   /usr/bin/login
        17726 S    -/bin/zsh
        18421 S+   herdr

        """
    let formatted = try #require(ProcessListing.pidStatComm(table, tty: "ttys000", limit: 64 * 1024))
    #expect(formatted.split(separator: "\n").dropFirst() == fixture.split(separator: "\n").dropFirst())
    let parsed = try #require(TerminalForegroundProcesses.parse(formatted))
    #expect(parsed == TerminalForegroundProcesses.parse(fixture))
    #expect(parsed.map(\.name) == ["login", "-/bin/zsh", "herdr"])
    #expect(parsed.map(\.foreground) == [false, false, true])
    // No process on the tty is an empty read, as `ps -t` printed nothing; an oversized read is unreadable.
    #expect(ProcessListing.pidStatComm(table, tty: "ttys009", limit: 64 * 1024) == "")
    #expect(ProcessListing.pidStatComm(table, tty: "ttys000", limit: formatted.utf8.count - 1) == nil)
}

@Test func stateLettersAndFlags() {
    #expect(ProcessListing.stat(record(1, ppid: 0, state: .stopped, name: "x", arguments: nil)) == "T")
    #expect(ProcessListing.stat(record(1, ppid: 0, state: .zombie, name: "x", arguments: nil)) == "Z")
    #expect(ProcessListing.stat(codexInTmux) == "Ss+")
}

@Test func parentShapeMatchesPS() {
    #expect(ProcessListing.pidPPID([launchd, login, loginShell, appServer])
                == "    1     0\n17717 17676\n17726 17717\n97265     1\n")
}

@Test func anEmptyFirstArgumentFallsBackToTheShortName() {
    // An empty name would make the whole `ps -t` read malformed.
    let blank = record(600, ppid: 1, tty: "ttys001", name: "python3", arguments: [""])
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
