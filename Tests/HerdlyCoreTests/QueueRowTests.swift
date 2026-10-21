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

@Test func sessionNameDropsTheSourcePrefixAndFallsBackToTheShortIdentifier() {
    #expect(QueueRowPresentation.sessionName(codexCLI, names: [codexCLI: "Fix sort order"]) == "Fix sort order")
    #expect(QueueRowPresentation.sessionName(codexCLI) == "session 3f9a2c1e")
    #expect(QueueRowPresentation.sessionName(codexCLI, names: [codexCLI: ""]) == "session 3f9a2c1e")
    // A name for another session never labels this one.
    #expect(QueueRowPresentation.sessionName(codexDesktop, names: [codexCLI: "Fix sort order"]) == "session 3f9a2c1e")
}

@Test func placeFollowsTheLabelFormatAndLeavesOutMissingParts() {
    let directory = "/Users/u/code/herdly"
    // Repo @ branch is the default (D21).
    #expect(QueueRowPresentation.place(directory: directory, branch: "fix/182-sort") == "herdly @ fix/182-sort")
    #expect(QueueRowPresentation.place(directory: directory, branch: "fix/182-sort", format: .repoAtBranch) == "herdly @ fix/182-sort")
    #expect(QueueRowPresentation.place(directory: directory, branch: "fix/182-sort", format: .repoOnly) == "herdly")
    #expect(QueueRowPresentation.place(directory: directory, branch: "fix/182-sort", format: .branchOnly) == "fix/182-sort")
    // A missing branch leaves the repo alone, or nothing when only the branch was asked for.
    #expect(QueueRowPresentation.place(directory: "/Users/u/code/herdly/", branch: nil) == "herdly")
    #expect(QueueRowPresentation.place(directory: directory, branch: "") == "herdly")
    #expect(QueueRowPresentation.place(directory: directory, branch: nil, format: .repoOnly) == "herdly")
    #expect(QueueRowPresentation.place(directory: directory, branch: nil, format: .branchOnly) == nil)
    #expect(QueueRowPresentation.place(directory: directory, branch: "", format: .branchOnly) == nil)
    // A missing repo shows nothing: the branch is only ever read from the repo's directory.
    for format in QueueLabelFormat.allCases {
        #expect(QueueRowPresentation.place(directory: nil, branch: "main", format: format) == nil)
        #expect(QueueRowPresentation.place(directory: "  ", branch: "main", format: format) == nil)
        #expect(QueueRowPresentation.place(directory: "/", branch: "main", format: format) == nil)
    }
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

@Test func exceptionWordAppearsOnlyWhenARowIsOffItsNormalPath() {
    var queue = AgentAttentionQueue()
    let codex = { (name: String) in AgentSessionIdentity(source: .codex, sourceScope: "codex", session: name, surface: .cli) }
    let idle = AgentSessionIdentity(source: .claude, sourceScope: "root", session: "idle", surface: .cli)
    queue.apply(.approval(AgentApproval(session: codex("live"), turn: "t1", call: "a1", arrivedAt: 100)))
    queue.apply(.question(AgentQuestion(session: codex("asked"), turn: "t2", call: "q1", arrivedAt: 100)))
    queue.apply(.outcome(AgentOutcome(session: codex("done"), turn: "t3", status: .finished, arrivedAt: 100)))
    queue.apply(.outcome(AgentOutcome(session: codex("broke"), turn: "t4", status: .failed, arrivedAt: 100)))
    queue.apply(.outcome(AgentOutcome(session: codex("halted"), turn: "t5", status: .stopped, arrivedAt: 100)))
    queue.apply(.outcome(AgentOutcome(session: codex("unknown"), turn: "t6", status: .unavailable, arrivedAt: 100)))
    queue.apply(.running(AgentRunning(session: codex("busy"), turn: "t7", arrivedAt: 100)))
    queue.apply(.running(AgentRunning(session: idle, turn: "t8", arrivedAt: 100, status: .waiting)))

    let words = Dictionary(uniqueKeysWithValues: queue.items(at: 101).map {
        ($0.session.session, QueueRowPresentation.exception($0)?.word)
    })
    // D17: approve, answer, check, and stopped are said by the section heading, so they get no word.
    #expect(words["live"] == .some(nil))
    #expect(words["asked"] == .some(nil))
    #expect(words["done"] == .some(nil))
    #expect(words["halted"] == .some(nil))
    #expect(words["busy"] == .some(nil))
    #expect(words["broke"] == "Failed")
    #expect(words["unknown"] == "Status unknown")
    #expect(words["idle"] == "Waiting")

    // Past its deadline the same approval is handed back, and its word says so.
    let later = queue.items(at: 1_000)
    #expect(later.first { $0.session == codex("live") }.flatMap(QueueRowPresentation.exception)?.word == "Handed back")
    // An Earlier result keeps its word.
    let earlier = later.first { $0.session == codex("broke") }
    #expect(earlier?.kind == .earlierOutcome)
    #expect(earlier.flatMap(QueueRowPresentation.exception) == .failed)
}

@Test func onlyAFailureIsMarkedAsAFailure() {
    #expect(RowException.failed.isFailure)
    #expect(!RowException.handedBack.isFailure)
    #expect(!RowException.waiting.isFailure)
    #expect(!RowException.statusUnknown.isFailure)
}

@Test func aStatusUnavailableSessionReadsStatusUnknownWithNoAge() {
    var queue = AgentAttentionQueue()
    queue.apply(.unavailable(sourceScope: "/tmp/root", observedAt: 2, reason: "duplicate",
                             ambiguousSessionIDs: ["11111111-1111-4111-8111-111111111111"]))
    let row = queue.items(at: 500).first
    #expect(row?.kind == .statusUnavailable)
    #expect(row.flatMap(QueueRowPresentation.exception) == .statusUnknown)
    // It has no arrival time, so its age lane reads a dash rather than "<1m".
    #expect(row.map { QueueRowPresentation.rowAge($0, now: 500) } == RowAge(text: "—", spoken: "No update time"))
}

@Test func rowAgeReadsFromTheRowsLatestEvidence() {
    var queue = AgentAttentionQueue()
    queue.apply(.running(AgentRunning(session: codexCLI, turn: "t1", arrivedAt: 0, updatedAt: 100)))
    let row = queue.items(at: 400)[0]
    #expect(QueueRowPresentation.rowAge(row, now: 400) == RowAge(text: "5m", spoken: "Updated 5 minutes ago"))
}

@Test func secondsLeftCountsDownTheRequestsOwnWindow() {
    // A 30-second window received at 100.
    let start = ApprovalCountdown(arrivedAt: 100, expiresAt: 130, now: 100)
    #expect(start.seconds == 30 && start.fraction == 1)
    #expect(start.label == "30s left" && start.spoken == "30 seconds left")

    // Partial seconds round up, so "0s" appears only at the deadline itself.
    let mid = ApprovalCountdown(arrivedAt: 100, expiresAt: 130, now: 112.2)
    #expect(mid.seconds == 18 && mid.label == "18s left")
    #expect(abs(mid.fraction - 17.8 / 30) < 0.000_1)
    let last = ApprovalCountdown(arrivedAt: 100, expiresAt: 130, now: 129.5)
    #expect(last.seconds == 1 && last.spoken == "1 second left")

    // Never negative, never past full.
    let over = ApprovalCountdown(arrivedAt: 100, expiresAt: 130, now: 200)
    #expect(over.seconds == 0 && over.fraction == 0)
    let early = ApprovalCountdown(arrivedAt: 100, expiresAt: 130, now: 50)
    #expect(early.seconds == 80 && early.fraction == 1)

    // A zero-length or inverted window has nothing left to show.
    #expect(ApprovalCountdown(arrivedAt: 100, expiresAt: 100, now: 100).fraction == 0)
    #expect(ApprovalCountdown(arrivedAt: 100, expiresAt: 90, now: 95).fraction == 0)
    #expect(ApprovalCountdown(arrivedAt: 100, expiresAt: .nan, now: 95) == ApprovalCountdown(seconds: 0, fraction: 0))
}

@Test func onlyALiveApprovalShowsSecondsLeftAndAMergedOneUsesItsSoonestDeadline() {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: codexCLI, turn: "t1", call: "a1", arrivedAt: 100, expiresAt: 140)))
    // The same request seen again with an earlier deadline keeps the earlier one.
    queue.apply(.approval(AgentApproval(session: codexCLI, turn: "t1", call: "a1", arrivedAt: 105, expiresAt: 130)))
    queue.apply(.outcome(AgentOutcome(session: codexDesktop, turn: "t2", status: .finished, arrivedAt: 100)))
    let rows = queue.items(at: 115)
    #expect(QueueRowPresentation.countdown(rows[0], now: 115) == ApprovalCountdown(seconds: 15, fraction: 0.5))
    #expect(QueueRowPresentation.countdown(rows[1], now: 115) == nil)
    // Handed back: no countdown.
    #expect(queue.items(at: 131).compactMap { QueueRowPresentation.countdown($0, now: 131) }.isEmpty)
}

@Test func onlyAShellCommandsDisclosureCallsItACommand() {
    #expect(ToolAction(name: "Bash", input: ["command": "swift test"])?.disclosureTitle == "Show full command")
    #expect(ToolAction(name: "exec_command", input: ["cmd": "ls"])?.disclosureTitle == "Show full command")
    #expect(ToolAction(name: "Edit", input: ["file_path": "/a/b.swift"])?.disclosureTitle == "Show full action")
    #expect(ToolAction(name: "Grep", input: ["pattern": "x"])?.disclosureTitle == "Show full action")
}

@Test func spokenHeadingReadsNamePlaceNoteStateAndSecondsLeft() {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: codexCLI, turn: "t1", call: "a1", arrivedAt: 100)))
    queue.apply(.outcome(AgentOutcome(session: claude, turn: "t2", status: .failed, arrivedAt: 100)))
    let rows = queue.items(at: 112)
    let approval = rows[0], failed = rows[1]
    let countdown = QueueRowPresentation.countdown(approval, now: 112)

    #expect(QueueRowPresentation.spokenHeading(approval, name: "Fix sort", place: "herdly @ main", note: nil,
                                                countdown: countdown)
            == "Fix sort, herdly @ main, Permission needed, 18 seconds left")
    // A row note no longer hides the place: both are read, then the state.
    #expect(QueueRowPresentation.spokenHeading(approval, name: "Fix sort", place: "herdly @ main", note: .sending,
                                                countdown: nil)
            == "Fix sort, herdly @ main, Sending…, Permission needed")
    // Missing parts are left out; the state is always read.
    #expect(QueueRowPresentation.spokenHeading(failed, name: "session abcdef12", place: nil, note: nil, countdown: nil)
            == "session abcdef12, Claude failed")
}

@Test func spokenStateNamesEveryKindInFull() {
    var queue = AgentAttentionQueue()
    let codex = { (name: String) in AgentSessionIdentity(source: .codex, sourceScope: "codex", session: name, surface: .cli) }
    queue.apply(.approval(AgentApproval(session: codex("live"), turn: "t", call: "a", arrivedAt: 100)))
    queue.apply(.approval(AgentApproval(session: claude, turn: "t", call: "a", arrivedAt: 0, expiresAt: 1)))
    queue.apply(.question(AgentQuestion(session: codex("asked"), turn: "t", call: "q", arrivedAt: 100)))
    queue.apply(.outcome(AgentOutcome(session: codex("done"), turn: "t", status: .finished, arrivedAt: 100)))
    queue.apply(.outcome(AgentOutcome(session: codex("odd"), turn: "t", status: .unavailable, arrivedAt: 100)))
    queue.apply(.running(AgentRunning(session: codex("busy"), turn: "t", arrivedAt: 100)))
    let states = Dictionary(uniqueKeysWithValues: queue.items(at: 101).map {
        ($0.session.session, QueueRowPresentation.spokenState($0))
    })
    #expect(states["live"] == "Permission needed")
    #expect(states[claude.session] == "Continue in Claude")
    #expect(states["asked"] == "Codex needs an answer")
    #expect(states["done"] == "Codex finished")
    #expect(states["odd"] == "Codex status unavailable")
    #expect(states["busy"] == "Working")
}
