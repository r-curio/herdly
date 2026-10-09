import Foundation
import Testing
@testable import SteerCore

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
    #expect(QueueRowPresentation.place(directory: "/Users/u/code/steer", branch: "fix/182-sort") == "steer @ fix/182-sort")
    #expect(QueueRowPresentation.place(directory: "/Users/u/code/steer/", branch: nil) == "steer")
    #expect(QueueRowPresentation.place(directory: "/Users/u/code/steer", branch: "") == "steer")
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
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-branch-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func branchIsReadFromTheNearestGitDirectoryAbove() throws {
    let root = try temporaryTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let git = root.appendingPathComponent("repo/.git", isDirectory: true)
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    try "ref: refs/heads/fix/182-sort\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    let nested = root.appendingPathComponent("repo/Sources/SteerCore", isDirectory: true)
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
    try "gitdir: /nonexistent/steer/worktree\n".write(to: missing.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    #expect(GitBranchReader.branch(forDirectory: missing.path) == nil)
}
