import Foundation
import Testing
@testable import HerdlyCore

private let codexCLI = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "3F9A2C1E-0000-4000-8000-000000000001", surface: .cli)
private let codexDesktop = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "3f9a2c1e-0000-4000-8000-000000000002", surface: .desktop)
private let claude = AgentSessionIdentity(source: .claude, sourceScope: "/Users/u/.claude", session: "abcdef12-3456", surface: .cli)

@Test func ageStepsAtMinuteHourAndDayBoundaries() {
    #expect(QueueRowPresentation.age(since: 100, now: 100) == "<1m")
    #expect(QueueRowPresentation.age(since: 100, now: 159.9) == "<1m")
    #expect(QueueRowPresentation.age(since: 100, now: 160) == "1m")
    #expect(QueueRowPresentation.age(since: 0, now: 3_599) == "59m")
    #expect(QueueRowPresentation.age(since: 0, now: 3_600) == "1h")
    #expect(QueueRowPresentation.age(since: 0, now: 86_399) == "23h")
    #expect(QueueRowPresentation.age(since: 0, now: 86_400 * 3) == "3d")
}

@Test func spokenAgeUsesWholeWords() {
    #expect(QueueRowPresentation.spokenAge(since: 0, now: 30) == "Updated less than a minute ago")
    #expect(QueueRowPresentation.spokenAge(since: 0, now: 60) == "Updated 1 minute ago")
    #expect(QueueRowPresentation.spokenAge(since: 0, now: 7_300) == "Updated 2 hours ago")
    #expect(QueueRowPresentation.spokenAge(since: 0, now: 86_400) == "Updated 1 day ago")
}

@Test func ageFromAFutureTimestampReadsAsJustNow() {
    #expect(QueueRowPresentation.age(since: 500, now: 100) == "<1m")
}

@Test func sourceTagNamesTheAgentAndCodexSurface() {
    #expect(QueueRowPresentation.sourceTag(codexCLI) == "Codex CLI")
    #expect(QueueRowPresentation.sourceTag(codexDesktop) == "Codex app")
    #expect(QueueRowPresentation.sourceTag(claude) == "Claude")
}

@Test func sessionNameDropsTheSourcePrefixAndFallsBackToTheShortIdentifier() {
    #expect(QueueRowPresentation.sessionName(codexCLI, names: [codexCLI: "Fix sort order"]) == "Fix sort order")
    #expect(QueueRowPresentation.sessionName(codexCLI) == "session 3f9a2c1e")
    #expect(QueueRowPresentation.sessionName(codexCLI, names: [codexCLI: ""]) == "session 3f9a2c1e")
    // A name for another session never labels this one.
    #expect(QueueRowPresentation.sessionName(codexDesktop, names: [codexCLI: "Fix sort order"]) == "session 3f9a2c1e")
}

@Test func placeJoinsProjectFolderAndBranch() {
    #expect(QueueRowPresentation.place(directory: "/Users/u/code/herdly", branch: "fix/182-sort") == "herdly @ fix/182-sort")
    #expect(QueueRowPresentation.place(directory: "/Users/u/code/herdly/", branch: nil) == "herdly")
    #expect(QueueRowPresentation.place(directory: "/Users/u/code/herdly", branch: "") == "herdly")
    #expect(QueueRowPresentation.place(directory: nil, branch: "main") == nil)
    #expect(QueueRowPresentation.place(directory: "  ", branch: "main") == nil)
    #expect(QueueRowPresentation.place(directory: "/", branch: "main") == nil)
}

@Test func headParsesBranchRefsAndDetachedCommits() {
    #expect(GitBranchReader.head("ref: refs/heads/main\n") == "main")
    #expect(GitBranchReader.head("ref: refs/heads/feat/queue-row-identity") == "feat/queue-row-identity")
    #expect(GitBranchReader.head("DA6B739565DF86BEF3D2DB880DFA3D47AAC05B4A\n") == "da6b739")
    #expect(GitBranchReader.head("ref: refs/remotes/origin/main") == nil)
    #expect(GitBranchReader.head("ref: refs/heads/") == nil)
    #expect(GitBranchReader.head("not a head") == nil)
    #expect(GitBranchReader.head("") == nil)
}

private func temporaryTree() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-branch-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func branchIsReadFromTheNearestGitDirectoryAbove() throws {
    let root = try temporaryTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let git = root.appendingPathComponent("repo/.git", isDirectory: true)
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    try "ref: refs/heads/fix/182-sort\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    let nested = root.appendingPathComponent("repo/Sources/HerdlyCore", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    #expect(GitBranchReader.branch(forDirectory: root.appendingPathComponent("repo").path) == "fix/182-sort")
    #expect(GitBranchReader.branch(forDirectory: nested.path) == "fix/182-sort")
    #expect(GitBranchReader.branch(forDirectory: root.path) == nil)
}

@Test func linkedWorktreeFollowsItsGitdirFile() throws {
    let root = try temporaryTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let gitdir = root.appendingPathComponent("main/.git/worktrees/side", isDirectory: true)
    try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: true)
    try "ref: refs/heads/feat/side\n".write(to: gitdir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    let absolute = root.appendingPathComponent("side", isDirectory: true)
    try FileManager.default.createDirectory(at: absolute, withIntermediateDirectories: true)
    try "gitdir: \(gitdir.path)\n".write(to: absolute.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    #expect(GitBranchReader.branch(forDirectory: absolute.path) == "feat/side")
    let relative = root.appendingPathComponent("relative", isDirectory: true)
    try FileManager.default.createDirectory(at: relative, withIntermediateDirectories: true)
    try "gitdir: ../main/.git/worktrees/side\n".write(to: relative.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    #expect(GitBranchReader.branch(forDirectory: relative.path) == "feat/side")
}

@Test func malformedSymlinkedOrOversizedHeadsReadAsNoBranch() throws {
    let root = try temporaryTree()
    defer { try? FileManager.default.removeItem(at: root) }
    func repo(_ name: String) throws -> URL {
        let git = root.appendingPathComponent("\(name)/.git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        return git
    }
    try "garbage".write(to: try repo("malformed").appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    #expect(GitBranchReader.branch(forDirectory: root.appendingPathComponent("malformed").path) == nil)

    let real = root.appendingPathComponent("real-head")
    try "ref: refs/heads/main\n".write(to: real, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: try repo("linked").appendingPathComponent("HEAD"), withDestinationURL: real)
    #expect(GitBranchReader.branch(forDirectory: root.appendingPathComponent("linked").path) == nil)

    let big = "ref: refs/heads/" + String(repeating: "x", count: GitBranchReader.maximumBytes)
    try big.write(to: try repo("oversized").appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    #expect(GitBranchReader.branch(forDirectory: root.appendingPathComponent("oversized").path) == nil)

    let missing = root.appendingPathComponent("dangling", isDirectory: true)
    try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
    try "gitdir: /nonexistent/herdly/worktree\n".write(to: missing.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    #expect(GitBranchReader.branch(forDirectory: missing.path) == nil)
}

@Test func attentionTagSaysWhatTheRowNeedsAndLeavesWorkingRowsUntagged() {
    var queue = AgentAttentionQueue()
    let live = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "live", surface: .cli)
    let asked = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "asked", surface: .cli)
    let done = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "done", surface: .cli)
    let broke = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "broke", surface: .cli)
    let halted = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "halted", surface: .cli)
    let unknown = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "unknown", surface: .cli)
    let busy = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "busy", surface: .cli)
    queue.apply(.approval(AgentApproval(session: live, turn: "t1", call: "a1", arrivedAt: 100)))
    queue.apply(.question(AgentQuestion(session: asked, turn: "t2", call: "q1", arrivedAt: 100)))
    queue.apply(.outcome(AgentOutcome(session: done, turn: "t3", status: .finished, arrivedAt: 100)))
    queue.apply(.outcome(AgentOutcome(session: broke, turn: "t4", status: .failed, arrivedAt: 100)))
    queue.apply(.outcome(AgentOutcome(session: halted, turn: "t5", status: .stopped, arrivedAt: 100)))
    queue.apply(.outcome(AgentOutcome(session: unknown, turn: "t6", status: .unavailable, arrivedAt: 100)))
    queue.apply(.running(AgentRunning(session: busy, turn: "t7", arrivedAt: 100)))

    let tags = Dictionary(uniqueKeysWithValues: queue.items(at: 101).map {
        ($0.session.session, QueueRowPresentation.attentionTag($0))
    })
    #expect(tags["live"] == "approve")
    #expect(tags["asked"] == "answer")
    #expect(tags["done"] == "check")
    #expect(tags["broke"] == "failed")
    #expect(tags["halted"] == "stopped")
    #expect(tags["unknown"] == "status unknown")
    #expect(tags["busy"] == .some(nil))

    // Past its deadline the same approval is handed back, and its tag says so.
    let expired = queue.items(at: 1_000).first { $0.session == live }
    #expect(expired.flatMap(QueueRowPresentation.attentionTag) == "handed back")
}
