import Foundation
import Testing
@testable import HerdlyApp
@testable import HerdlyCore

// MARK: - Fixtures

private let sessionA = AgentSessionIdentity(source: .claude, sourceScope: "/u/.claude", session: "a", surface: .cli)
private let sessionB = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "b", surface: .cli)
private let turnA = AgentTurnIdentity(session: sessionA, turn: "t1")
private let turnA2 = AgentTurnIdentity(session: sessionA, turn: "t2")
private let turnB = AgentTurnIdentity(session: sessionB, turn: "t1")
private let commit = "a6b1eae4f3c22fb3ae5cfd2a2d340710203fd0c4"
private let feature = WorkBranch.branch(name: "feat/x", directory: "/w/repo", startedAt: 1_000, repository: "o/repo")

/// `git status --porcelain=v2 --branch` output.
private func status(head: String = "feat/x", upstream: String? = "origin/feat/x", ahead: Int? = 0,
                    entries: [String] = [], oid: String = commit) -> String {
    var lines = ["# branch.oid \(oid)", "# branch.head \(head)"]
    if let upstream { lines.append("# branch.upstream \(upstream)") }
    if let ahead { lines.append("# branch.ab +\(ahead) -0") }
    return (lines + entries).joined(separator: "\n") + "\n"
}

/// `gh pr list --json ...` output, shaped like the captures in docs/evidence/github-pr-status.md.
private func pullRequests(_ entries: [String]) -> Data { Data("[\(entries.joined(separator: ","))]".utf8) }

private func pr(number: Int = 7, state: String = "OPEN", branch: String = "feat/x", fork: Bool = false,
                mergedAt: String? = nil, mergeable: String = "MERGEABLE", checks: [String] = [checkRun("SUCCESS")]) -> String {
    let merged = mergedAt.map { "\"\($0)\"" } ?? "null"
    return """
    {"number":\(number),"state":"\(state)","headRefName":"\(branch)","headRefOid":"\(commit)",\
    "isCrossRepository":\(fork),"mergedAt":\(merged),"mergeable":"\(mergeable)",\
    "statusCheckRollup":[\(checks.joined(separator: ","))]}
    """
}

private func checkRun(_ conclusion: String?, status: String = "COMPLETED") -> String {
    let value = conclusion.map { "\"\($0)\"" } ?? "\"\""
    return #"{"__typename":"CheckRun","name":"swift","status":"\#(status)","conclusion":\#(value),"workflowName":"macOS"}"#
}

private func statusContext(_ state: String) -> String {
    #"{"__typename":"StatusContext","context":"ci","state":"\#(state)"}"#
}

private func lookup(_ entries: [String], branch: String = "feat/x", startedAt: Double = 1_000) -> GitHubPullRequestLookup {
    GitHubPullRequestReader.parse(pullRequests(entries), branch: branch, turnStartedAt: startedAt)
}

private func open(_ checks: GitHubPullRequest.Checks, mergeable: GitHubPullRequest.Mergeable = .mergeable)
    -> GitHubPullRequestLookup {
    .found(GitHubPullRequest(number: 7, state: .open, headCommit: commit, mergeable: mergeable, checks: checks))
}

private let mergedPR = GitHubPullRequestLookup.found(GitHubPullRequest(number: 7, state: .merged, mergedAt: 2_000))

// MARK: - Local git output

@Test func porcelainReadsACleanPushedBranch() throws {
    let reading = try #require(GitLocalReading.parse(status: status()))
    #expect(reading.head == .branch("feat/x"))
    #expect(reading.commit == commit)
    #expect(reading.hasUpstream && !reading.changed)
    #expect(reading.unpushed == 0)
}

@Test func porcelainCountsChangedUntrackedAndConflictedEntriesAsUncommitted() {
    for entry in ["1 .M N... 100644 100644 100644 abc abc file.swift", "? new.swift",
                  "2 R. N... 100644 100644 100644 abc abc R100 new\told", "u UU N... 1 2 3 4 a b c f"] {
        #expect(GitLocalReading.parse(status: status(entries: [entry]))?.changed == true)
    }
}

@Test func porcelainReadsAheadDetachedInitialAndGoneUpstream() {
    #expect(GitLocalReading.parse(status: status(ahead: 3))?.unpushed == 3)
    #expect(GitLocalReading.parse(status: status(head: "(detached)", upstream: nil, ahead: nil))?.head == .detached("a6b1eae"))
    let initial = GitLocalReading.parse(status: status(upstream: nil, ahead: nil, oid: "(initial)"))
    #expect(initial?.commit == nil && initial?.unpushed == nil)
    // An upstream whose branch was deleted has no ahead/behind line: unpushed is unknown.
    let gone = GitLocalReading.parse(status: status(ahead: nil))
    #expect(gone?.hasUpstream == true && gone?.unpushed == nil)
}

@Test func malformedPorcelainIsNoReading() {
    #expect(GitLocalReading.parse(status: "") == nil)
    #expect(GitLocalReading.parse(status: "fatal: not a git repository\n") == nil)
    #expect(GitLocalReading.parse(status: "# branch.head main\n") == nil)
    #expect(GitLocalReading.parse(status: status() + "garbage line\n") == nil)
    #expect(GitLocalReading.parse(status: status(ahead: nil) + "# branch.ab +x -0\n") == nil)
    #expect(GitLocalReading.parse(status: status(oid: "not-a-commit")) == nil)
    #expect(GitLocalReading.parseCount(" 12\n") == 12)
    #expect(GitLocalReading.parseCount("-1") == nil && GitLocalReading.parseCount("lots") == nil)
}

@Test func onlyGitHubRemotesNameARepository() {
    #expect(GitHubRepositoryName.parse(remoteURL: "git@github.com:r-curio/herdly.git\n") == "r-curio/herdly")
    #expect(GitHubRepositoryName.parse(remoteURL: "https://github.com/r-curio/herdly") == "r-curio/herdly")
    #expect(GitHubRepositoryName.parse(remoteURL: "https://user:secret@github.com/o/r.git/") == "o/r")
    #expect(GitHubRepositoryName.parse(remoteURL: "ssh://git@github.com/o/r.git") == "o/r")
    #expect(GitHubRepositoryName.parse(remoteURL: "git@gitlab.com:o/r.git") == nil)
    #expect(GitHubRepositoryName.parse(remoteURL: "https://github.com.evil.example/o/r") == nil)
    #expect(GitHubRepositoryName.parse(remoteURL: "/srv/git/repo.git") == nil)
    #expect(GitHubRepositoryName.parse(remoteURL: "https://github.com/o/r/extra") == nil)
    #expect(GitHubRepositoryName.parse(remoteURL: "https://github.com/../r") == nil)
}

// MARK: - gh output

@Test func ghFindsAMergedPullRequestWhoseBranchWasDeleted() {
    // The evidence shows `--state all --head` still lists it after the branch is gone.
    #expect(lookup([pr(state: "MERGED", mergedAt: "2026-11-11T04:43:51Z", mergeable: "UNKNOWN")], startedAt: 0)
        == .found(GitHubPullRequest(number: 7, state: .merged, mergedAt: 1_794_372_231, headCommit: commit,
                                    mergeable: .unknown, checks: .passed)))
}

@Test func aMergeFromBeforeTheTurnIsNotThisTurnsWork() {
    let startedAfter = Date(timeIntervalSince1970: 1_794_372_231 + 60).timeIntervalSince1970
    #expect(lookup([pr(state: "MERGED", mergedAt: "2026-11-11T04:43:51Z")], startedAt: startedAfter) == GitHubPullRequestLookup.none)
}

@Test func ghReadsChecksAndMergeability() {
    func checks(_ entries: [String]) -> GitHubPullRequest.Checks? {
        if case .found(let request) = lookup([pr(checks: entries)]) { return request.checks }
        return nil
    }
    #expect(checks([checkRun("SUCCESS"), checkRun("SKIPPED"), statusContext("SUCCESS")]) == .passed)
    #expect(checks([checkRun("SUCCESS"), checkRun(nil, status: "IN_PROGRESS")]) == .running)
    #expect(checks([statusContext("PENDING")]) == .running)
    #expect(checks([checkRun("FAILURE"), checkRun(nil, status: "QUEUED")]) == .failing)
    #expect(checks([statusContext("ERROR")]) == .failing)
    #expect(checks([]) == GitHubPullRequest.Checks.none)
    #expect(checks([checkRun("SOMETHING_NEW")]) == .unknown)
    if case .found(let request) = lookup([pr(mergeable: "CONFLICTING")]) {
        #expect(request.mergeable == .conflicting)
    } else { Issue.record("expected a pull request") }
}

@Test func ghIgnoresForksOtherBranchesAndClosedPullRequests() {
    #expect(lookup([pr(fork: true)]) == GitHubPullRequestLookup.none)
    #expect(lookup([pr(branch: "feat/other")]) == GitHubPullRequestLookup.none)
    #expect(lookup([pr(state: "CLOSED")]) == GitHubPullRequestLookup.none)
    #expect(lookup([]) == GitHubPullRequestLookup.none)
}

@Test func twoOpenPullRequestsForOneBranchChooseNone() {
    #expect(lookup([pr(number: 1), pr(number: 2)]) == .ambiguous)
}

@Test func unreadableGhOutputIsUnavailable() {
    #expect(GitHubPullRequestReader.parse(Data("not json".utf8), branch: "feat/x", turnStartedAt: 0) == .unavailable)
    #expect(lookup([pr(state: "DRAFTY")]) == .unavailable)
    #expect(lookup([pr(state: "MERGED", mergedAt: "yesterday")]) == .unavailable)
    let oversized = Data(repeating: 0x20, count: GitHubPullRequestReader.maximumBytes + 1)
    #expect(GitHubPullRequestReader.parse(oversized, branch: "feat/x", turnStartedAt: 0) == .unavailable)
}

// MARK: - The verdict

@Test func everyVerdictFromFixtures() throws {
    let clean = try #require(GitLocalReading.parse(status: status()))
    let dirty = try #require(GitLocalReading.parse(status: status(entries: ["? new.swift"])))
    let ahead = try #require(GitLocalReading.parse(status: status(ahead: 2)))
    func verdict(_ local: GitLocalReading?, _ pr: GitHubPullRequestLookup?) -> WorkStatus {
        WorkStatusRule.verdict(branch: feature, local: local, pullRequest: pr)
    }
    #expect(verdict(dirty, GitHubPullRequestLookup.none) == .uncommitted)
    #expect(verdict(ahead, open(.passed)) == .notPushed)
    #expect(verdict(clean, open(.running)) == .checksRunning)
    #expect(verdict(clean, open(.failing)) == .checksFailing)
    #expect(verdict(clean, open(.passed, mergeable: .conflicting)) == .conflict)
    #expect(verdict(clean, open(.passed)) == .checksPassed)
    #expect(verdict(dirty, mergedPR) == .merged)
    #expect(verdict(clean, GitHubPullRequestLookup.none) == WorkStatus.none)
    #expect(verdict(clean, open(.none)) == WorkStatus.none)
    #expect(verdict(clean, open(.unknown)) == WorkStatus.none)
}

@Test func aFolderThatMovedOnSaysNothingAboutTheRememberedBranch() throws {
    // The agent merged and went back to main, where there are unrelated changes.
    let main = try #require(GitLocalReading.parse(status: status(head: "main", upstream: "origin/main",
                                                                  entries: ["? scratch.txt"])))
    #expect(WorkStatusRule.verdict(branch: feature, local: main, pullRequest: mergedPR) == .merged)
    #expect(WorkStatusRule.verdict(branch: feature, local: main, pullRequest: .unavailable) == WorkStatus.none)
    #expect(WorkStatusRule.verdict(branch: feature, local: main, pullRequest: open(.failing)) == .checksFailing)
    // A folder that cannot be read (deleted worktree, timeout) still shows a merge, but nothing open.
    #expect(WorkStatusRule.verdict(branch: feature, local: nil, pullRequest: mergedPR) == .merged)
    #expect(WorkStatusRule.verdict(branch: feature, local: nil, pullRequest: open(.passed)) == WorkStatus.none)
}

@Test func aMissingSignedOutOrFailingGhNeverGoesBeyondLocalGit() throws {
    let clean = try #require(GitLocalReading.parse(status: status()))
    let dirty = try #require(GitLocalReading.parse(status: status(entries: ["? a"])))
    let ahead = try #require(GitLocalReading.parse(status: status(ahead: 1)))
    for failed in [GitHubPullRequestLookup.unavailable, nil, .ambiguous] {
        #expect(WorkStatusRule.verdict(branch: feature, local: clean, pullRequest: failed) == WorkStatus.none)
        #expect(WorkStatusRule.verdict(branch: feature, local: dirty, pullRequest: failed) == .uncommitted)
        #expect(WorkStatusRule.verdict(branch: feature, local: ahead, pullRequest: failed) == .notPushed)
        #expect(WorkStatusRule.verdict(branch: feature, local: nil, pullRequest: failed) == WorkStatus.none)
    }
}

@Test func anUnknownUnpushedCountClaimsNothingPastIt() throws {
    let gone = try #require(GitLocalReading.parse(status: status(ahead: nil)))
    #expect(WorkStatusRule.verdict(branch: feature, local: gone, pullRequest: open(.passed)) == WorkStatus.none)
    #expect(WorkStatusRule.verdict(branch: feature, local: gone, pullRequest: mergedPR) == .merged)
}

@Test func uncertainBranchesAndDetachedHeadsGiveAtMostUncommitted() throws {
    let dirty = try #require(GitLocalReading.parse(status: status(entries: ["? a"])))
    let detachedDirty = try #require(GitLocalReading.parse(status: status(head: "(detached)", upstream: nil, ahead: nil,
                                                                           entries: ["? a"])))
    #expect(WorkStatusRule.verdict(branch: .unknown, local: dirty, pullRequest: mergedPR) == WorkStatus.none)
    #expect(WorkStatusRule.verdict(branch: .ambiguous, local: dirty, pullRequest: mergedPR) == WorkStatus.none)
    #expect(WorkStatusRule.verdict(branch: .detached(directory: "/w/repo"), local: detachedDirty, pullRequest: mergedPR)
        == .uncommitted)
    #expect(WorkStatusRule.verdict(branch: .detached(directory: "/w/repo"), local: dirty, pullRequest: nil) == WorkStatus.none)
}

// MARK: - Branch memory

private func sighting(_ turn: AgentTurnIdentity, _ directory: String = "/w/repo", _ head: GitHead? = .branch("feat/x"),
                      at startedAt: Double = 1_000) -> WorkBranchSighting {
    WorkBranchSighting(turn: turn, startedAt: startedAt, directory: directory, head: head)
}

@Test func theBranchSeenWhileTheTurnRanIsRemembered() {
    var memory = WorkBranchMemory()
    memory.observe([sighting(turnA)])
    memory.record(.gitHub("o/repo"), for: turnA)
    #expect(memory.branch(for: turnA) == feature)
    #expect(memory.branch(for: turnB) == .unknown)
}

@Test func duplicateAndReorderedSightingsRememberTheSameBranch() {
    var forward = WorkBranchMemory(), backward = WorkBranchMemory()
    let scans = [[sighting(turnA, at: 1_005)], [sighting(turnA, at: 1_000)], [sighting(turnA, at: 1_000)],
                 [sighting(turnA, "/w/repo/", nil, at: 1_010)]]
    for scan in scans { forward.observe(scan) }
    for scan in scans.reversed() { backward.observe(scan) }
    #expect(forward == backward)
    #expect(forward.branch(for: turnA) == .branch(name: "feat/x", directory: "/w/repo", startedAt: 1_000, repository: nil))
}

@Test func aBranchChangedMidTurnHasNoVerdict() {
    var memory = WorkBranchMemory()
    memory.observe([sighting(turnA)])
    memory.observe([sighting(turnA, "/w/repo", .branch("main"))])
    #expect(memory.branch(for: turnA) == .ambiguous)
    var moved = WorkBranchMemory()
    moved.observe([sighting(turnA)])
    moved.observe([sighting(turnA, "/w/other")])
    #expect(moved.branch(for: turnA) == .ambiguous)
}

@Test func twoSessionsInOneFolderDuringTheTurnHaveNoVerdict() {
    var memory = WorkBranchMemory()
    memory.observe([sighting(turnA)])
    memory.observe([sighting(turnA), sighting(turnB, "/w/repo/Sources")])
    memory.observe([sighting(turnA)])
    #expect(memory.branch(for: turnA) == .ambiguous)
    #expect(memory.branch(for: turnB) == .ambiguous)
    #expect(memory.unreadRepositories.isEmpty)
    // Two folders that only share a name prefix are not the same folder.
    var apart = WorkBranchMemory()
    apart.observe([sighting(turnA), sighting(turnB, "/w/repo-two")])
    #expect(apart.branch(for: turnA) != .ambiguous)
}

@Test func oneSessionsNextTurnIsNotASecondSession() {
    var memory = WorkBranchMemory()
    memory.observe([sighting(turnA), sighting(turnA2)])
    #expect(memory.branch(for: turnA) != .ambiguous)
}

@Test func aFinishedTurnIsNotReadWhileOtherWorkRunsInItsFolder() {
    #expect(WorkBranchMemory.busy("/w/repo", turn: turnA, running: [sighting(turnB, "/w/repo")]))
    #expect(WorkBranchMemory.busy("/w/repo", turn: turnA, running: [sighting(turnA2, "/w/repo")]))
    #expect(!WorkBranchMemory.busy("/w/repo", turn: turnA, running: [sighting(turnB, "/w/elsewhere")]))
}

@Test func aDetachedHeadIsRememberedWithoutABranch() {
    var memory = WorkBranchMemory()
    memory.observe([sighting(turnA, "/w/repo", .detached("a6b1eae"))])
    #expect(memory.branch(for: turnA) == .detached(directory: "/w/repo"))
    #expect(memory.unreadRepositories.isEmpty)
}

@Test func memoryKeepsOnlyRowsStillShownAndIsBounded() {
    var memory = WorkBranchMemory()
    memory.observe([sighting(turnA), sighting(turnB, "/w/b")])
    memory.retain([turnB])
    #expect(memory.branch(for: turnA) == .unknown)
    var many = WorkBranchMemory()
    many.observe((0..<(WorkBranchMemory.maximumTurns + 10)).map { index in
        sighting(AgentTurnIdentity(session: sessionA, turn: "t\(index)"), "/w/\(index)", at: Double(index))
    })
    #expect(many.entries.count == WorkBranchMemory.maximumTurns)
    #expect(many.branch(for: AgentTurnIdentity(session: sessionA, turn: "t0")) == .unknown)
}

@Test func branchReaderTellsADetachedHeadFromABranch() {
    #expect(GitBranchReader.parseHead("ref: refs/heads/feat/x\n") == .branch("feat/x"))
    #expect(GitBranchReader.parseHead("A6B1EAE4F3C22FB3AE5CFD2A2D340710203FD0C4\n") == .detached("a6b1eae"))
    #expect(GitBranchReader.head("ref: refs/heads/main") == "main")
}

// MARK: - Refresh schedule

@Test func checksRunningRefreshesOnAFixedIntervalUntilTheCap() {
    let running = WorkStatusReading(verdict: .checksRunning, readAt: 100, firstReadAt: 100)
    #expect(WorkStatusSchedule.isDue(nil, isEarlier: true, now: 0))
    #expect(!WorkStatusSchedule.isDue(running, isEarlier: false, now: 129))
    #expect(WorkStatusSchedule.isDue(running, isEarlier: false, now: 130))
    #expect(WorkStatusSchedule.isDue(running, isEarlier: true, now: 130))
    let late = WorkStatusReading(verdict: .checksRunning, readAt: 100 + 3_590, firstReadAt: 100)
    #expect(!WorkStatusSchedule.isDue(late, isEarlier: false, now: 100 + WorkStatusSchedule.cap))
}

@Test func settledVerdictsRefreshSlowlyAndEarlierTerminalRowsNever() {
    let failing = WorkStatusReading(verdict: .checksFailing, readAt: 100, firstReadAt: 100)
    #expect(!WorkStatusSchedule.isDue(failing, isEarlier: false, now: 219))
    #expect(WorkStatusSchedule.isDue(failing, isEarlier: false, now: 220))
    #expect(!WorkStatusSchedule.isDue(failing, isEarlier: true, now: 10_000 - 7_000))
    let uncommitted = WorkStatusReading(verdict: .uncommitted, readAt: 100, firstReadAt: 100)
    #expect(WorkStatusSchedule.isDue(uncommitted, isEarlier: true, now: 220))
    let merged = WorkStatusReading(verdict: .merged, readAt: 100, firstReadAt: 100)
    #expect(!WorkStatusSchedule.isDue(merged, isEarlier: false, now: 1_000))
}

// MARK: - GitHub CLI card and switch

@Test func ghVersionAndSignInAreRead() {
    #expect(GitHubCLIStatus.version("gh version 2.62.0 (2024-11-14)\nhttps://github.com/cli/cli/releases/tag/v2.62.0\n") == "2.62.0")
    #expect(GitHubCLIStatus.version("command not found") == nil)
    let signedIn = #"{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"me","tokenSource":"keyring"}]}}"#
    #expect(GitHubCLIStatus.signedIn(Data(signedIn.utf8)) == true)
    #expect(GitHubCLIStatus.signedIn(Data(#"{"hosts":{}}"#.utf8)) == false)
    let failing = #"{"hosts":{"github.com":[{"state":"error","active":true,"host":"github.com"}]}}"#
    #expect(GitHubCLIStatus.signedIn(Data(failing.utf8)) == nil)
    #expect(GitHubCLIStatus.signedIn(Data("nope".utf8)) == nil)
}

@Test func theCardReadsLikeThePaperFrames() {
    #expect(GitHubCLIStatus.signedIn(version: "2.62.0").subtitle == "GitHub CLI 2.62.0 · signed in to github.com")
    #expect(GitHubCLIStatus.signedIn(version: "2.62.0").header == .connected)
    #expect(GitHubCLIStatus.signedOut(version: "2.62.0").subtitle == "GitHub CLI 2.62.0 · signed out")
    #expect(GitHubCLIStatus.signedOut(version: "2.62.0").header == .attention("Sign in required"))
    #expect(!GitHubCLIStatus.signedOut(version: nil).isQuiet)
    #expect(GitHubCLIStatus.notInstalled.subtitle == "GitHub CLI not installed")
    #expect(GitHubCLIStatus.notInstalled.header == .attention("Not installed") && GitHubCLIStatus.notInstalled.isQuiet)
}

@Test func theSwitchIsOnByDefaultOnlyWhenSignedIn() {
    #expect(WorkStatusSetting.isOn(stored: nil, cli: .signedIn(version: nil)))
    #expect(!WorkStatusSetting.isOn(stored: nil, cli: .signedOut(version: nil)))
    #expect(!WorkStatusSetting.isOn(stored: nil, cli: .notInstalled))
    #expect(!WorkStatusSetting.isOn(stored: nil, cli: .checking))
    #expect(!WorkStatusSetting.isOn(stored: false, cli: .signedIn(version: nil)))
    #expect(WorkStatusSetting.isOn(stored: true, cli: .notInstalled))
}

@Test func theShellStubGitIsNeverUsed() {
    #expect(WorkStatusTools.git(home: "/h", isExecutable: { $0 == "/usr/bin/git" }) == nil)
    #expect(WorkStatusTools.git(home: "/h", isExecutable: { _ in true }) == "/opt/homebrew/bin/git")
    #expect(WorkStatusTools.gh(home: "/h", isExecutable: { $0 == "/h/.local/bin/gh" }) == "/h/.local/bin/gh")
    #expect(WorkStatusTools.gh(home: "/h", isExecutable: { _ in false }) == nil)
}

// MARK: - Reader with a fake runner

/// Answers each command by its first distinguishing argument and records every call.
private final class FakeRunner: WorkStatusCommandRunning, @unchecked Sendable {
    // `@unchecked Sendable`: `calls` is used only under `lock`.
    private let lock = NSLock()
    private var recorded: [WorkStatusCommand] = []
    let answer: @Sendable (WorkStatusCommand) -> WorkStatusCommandResult

    init(_ answer: @escaping @Sendable (WorkStatusCommand) -> WorkStatusCommandResult) { self.answer = answer }

    var calls: [WorkStatusCommand] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ command: WorkStatusCommand) -> WorkStatusCommandResult {
        lock.lock()
        recorded.append(command)
        lock.unlock()
        return answer(command)
    }
}

private func reply(status: String = status(), remote: String = "git@github.com:o/repo.git",
                   gh: WorkStatusCommandResult = .succeeded(pullRequests([pr(checks: [checkRun("FAILURE")])])))
    -> @Sendable (WorkStatusCommand) -> WorkStatusCommandResult {
    { command in
        if command.executable.hasSuffix("/gh") { return gh }
        if command.arguments.contains("status") { return .succeeded(Data(status.utf8)) }
        if command.arguments.contains("config") { return .succeeded(Data(remote.utf8)) }
        if command.arguments.contains("remote") { return .succeeded(Data("origin\n".utf8)) }
        if command.arguments.contains("rev-list") { return .succeeded(Data("0\n".utf8)) }
        return .failed(1)
    }
}

private func reader(_ runner: FakeRunner, open: Bool = true, gh: String? = "/opt/homebrew/bin/gh") -> WorkStatusReader {
    WorkStatusReader(runner: runner, gate: WorkStatusGate(open: open), git: "/opt/homebrew/bin/git", gh: gh, home: "/h")
}

@Test func theReaderCombinesGitAndGhReadOnly() {
    let runner = FakeRunner(reply())
    let reader = reader(runner)
    #expect(reader.repository("/w/repo") == .gitHub("o/repo"))
    #expect(reader.verdict(feature) == .checksFailing)
    let git = runner.calls.filter { $0.executable.hasSuffix("/git") }
    #expect(git.allSatisfy { $0.arguments.starts(with: ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C"]) })
    #expect(git.allSatisfy { $0.environment["GIT_OPTIONAL_LOCKS"] == "0" && $0.timeout == WorkStatusReader.gitTimeout })
    let gh = runner.calls.filter { $0.executable.hasSuffix("/gh") }
    #expect(gh.map(\.arguments) == [GitHubPullRequestReader.arguments(repository: "o/repo", branch: "feat/x")])
    #expect(gh.allSatisfy { $0.environment["GH_PROMPT_DISABLED"] == "1" && $0.environment["GH_TOKEN"] == nil })
}

@Test func theSwitchOffRunsNoCommand() {
    let runner = FakeRunner(reply())
    let reader = reader(runner, open: false)
    #expect(reader.verdict(feature) == WorkStatus.none)
    #expect(reader.repository("/w/repo") == .notOnGitHub)
    #expect(reader.verdict(.detached(directory: "/w/repo")) == WorkStatus.none)
    #expect(runner.calls.isEmpty)
}

@Test func aTimedOutOrFailingGitCommandGivesNoVerdict() {
    let timedOut = FakeRunner { command in
        command.executable.hasSuffix("/gh") ? .succeeded(pullRequests([pr()])) : .timedOut
    }
    #expect(reader(timedOut).verdict(feature) == WorkStatus.none)
    #expect(reader(timedOut).repository("/w/repo") == .notOnGitHub)
    let notATree = FakeRunner { _ in .failed(128) }
    #expect(reader(notATree).verdict(feature) == WorkStatus.none)
}

@Test func aMissingOrFailingGhKeepsOnlyTheLocalVerdict() {
    let dirty = status(entries: ["? new.swift"])
    #expect(reader(FakeRunner(reply(status: dirty)), gh: nil).verdict(feature) == .uncommitted)
    for failure in [WorkStatusCommandResult.failed(1), .timedOut, .notLaunched, .tooLarge, .succeeded(Data("<html>".utf8))] {
        #expect(reader(FakeRunner(reply(gh: failure))).verdict(feature) == WorkStatus.none)
        #expect(reader(FakeRunner(reply(status: dirty, gh: failure))).verdict(feature) == .uncommitted)
    }
}

@Test func aBranchWithoutUpstreamCountsCommitsOnNoRemote() {
    let runner = FakeRunner { command in
        if command.executable.hasSuffix("/gh") { return .succeeded(pullRequests([])) }
        if command.arguments.contains("status") { return .succeeded(Data(status(upstream: nil, ahead: nil).utf8)) }
        if command.arguments.contains("remote") { return .succeeded(Data("origin\n".utf8)) }
        if command.arguments.contains("rev-list") { return .succeeded(Data("4\n".utf8)) }
        return .failed(1)
    }
    #expect(reader(runner).verdict(feature) == .notPushed)
    let noRemote = FakeRunner { command in
        if command.arguments.contains("status") { return .succeeded(Data(status(upstream: nil, ahead: nil).utf8)) }
        if command.arguments.contains("remote") { return .succeeded(Data()) }
        return .failed(1)
    }
    #expect(reader(noRemote).verdict(feature) == WorkStatus.none)
    #expect(!noRemote.calls.contains { $0.arguments.contains("rev-list") })
}

@Test func aNonGitHubOriginMakesNoGitHubCall() {
    let runner = FakeRunner(reply(remote: "git@gitlab.com:o/repo.git"))
    #expect(reader(runner).repository("/w/repo") == .notOnGitHub)
    #expect(!runner.calls.contains { $0.executable.hasSuffix("/gh") })
}

@Test func theCardStatusComesFromGh() {
    let signedIn = #"{"hosts":{"github.com":[{"state":"success","active":true}]}}"#
    let runner = FakeRunner { command in
        command.arguments == ["--version"] ? .succeeded(Data("gh version 2.62.0 (2024-11-14)\n".utf8))
            : .succeeded(Data(signedIn.utf8))
    }
    #expect(reader(runner).cliStatus() == .signedIn(version: "2.62.0"))
    #expect(reader(FakeRunner { _ in .timedOut }).cliStatus() == .unknown(version: nil))
    #expect(reader(FakeRunner { _ in .timedOut }, gh: nil).cliStatus() == .notInstalled)
}

// MARK: - Model gating

private func item(running turn: AgentTurnIdentity) -> AgentAttentionItem {
    AgentAttentionItem(id: .running(turn), kind: .running, session: turn.session, arrivedAt: 1_000, approval: nil,
                       question: nil, outcome: nil, running: AgentRunning(session: turn.session, turn: turn.turn, arrivedAt: 1_000),
                       unavailableReason: nil)
}

private func item(finished turn: AgentTurnIdentity) -> AgentAttentionItem {
    AgentAttentionItem(id: .outcome(turn), kind: .outcome, session: turn.session, arrivedAt: 1_100, approval: nil,
                       question: nil, outcome: AgentOutcome(session: turn.session, turn: turn.turn, status: .finished,
                                                            arrivedAt: 1_100),
                       running: nil, unavailableReason: nil)
}

@MainActor @Test func theModelRunsNothingWhileTheSwitchIsOff() async throws {
    let suite = "herdly-work-status-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: WorkStatusSetting.defaultsKey)
    let runner = FakeRunner(reply())
    let gate = WorkStatusGate(open: true)
    let model = WorkStatusModel(reader: reader(runner).with(gate: gate), gate: gate, defaults: defaults)
    #expect(!gate.isOpen)
    model.scanned([item(running: turnA)], heads: ["/w/repo": .branch("feat/x")], directory: { _ in "/w/repo" }, now: 1_000)
    model.scanned([item(finished: turnA)], heads: [:], directory: { _ in "/w/repo" }, now: 1_100)
    try await Task.sleep(for: .milliseconds(200))
    #expect(runner.calls.isEmpty)
    #expect(model.verdict(for: turnA) == WorkStatus.none)
}

@MainActor @Test func theModelReadsAFinishedTurnOnItsRememberedBranch() async throws {
    let suite = "herdly-work-status-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: WorkStatusSetting.defaultsKey)
    let runner = FakeRunner(reply())
    let gate = WorkStatusGate(open: false)
    let model = WorkStatusModel(reader: reader(runner).with(gate: gate), gate: gate, defaults: defaults)
    #expect(gate.isOpen)
    model.scanned([item(running: turnA)], heads: ["/w/repo": .branch("feat/x")], directory: { _ in "/w/repo" }, now: 1_000)
    try await waitUntil { !model.memory.unreadRepositories.contains { $0.turn == turnA } }
    model.scanned([item(finished: turnA)], heads: [:], directory: { _ in "/w/repo" }, now: 1_100)
    try await waitUntil { model.readings[turnA] != nil }
    #expect(model.verdict(for: turnA) == .checksFailing)
    // Nothing is read while the switch is off, and what was read is forgotten.
    let before = runner.calls.count
    model.setEnabled(false)
    model.scanned([item(finished: turnA)], heads: [:], directory: { _ in "/w/repo" }, now: 5_000)
    try await Task.sleep(for: .milliseconds(100))
    #expect(runner.calls.count == before)
    #expect(model.verdict(for: turnA) == WorkStatus.none)
}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    #expect(condition())
}

private extension WorkStatusReader {
    func with(gate: WorkStatusGate) -> WorkStatusReader {
        WorkStatusReader(runner: runner, gate: gate, git: git, gh: gh, home: home)
    }
}

// MARK: - The real runner

@Test func theProcessRunnerStopsACommandPastItsWait() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-work-status-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let script = folder.appendingPathComponent("slow")
    try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let started = Date()
    let result = ProcessWorkStatusRunner().run(WorkStatusCommand(executable: script.path, arguments: [],
                                                                 environment: [:], timeout: 0.3))
    #expect(result == .timedOut)
    #expect(Date().timeIntervalSince(started) < 5)
    #expect(ProcessWorkStatusRunner().run(WorkStatusCommand(executable: folder.appendingPathComponent("none").path,
                                                            arguments: [], environment: [:], timeout: 1)) == .notLaunched)
}

/// A disposable repository in a temporary folder; skipped where no developer-tools git is installed.
@Test func aRealWorkTreeWithAnUntrackedFileReadsUncommitted() throws {
    guard let git = WorkStatusTools.git(home: NSHomeDirectory(), isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    else { return }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-work-tree-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let runner = ProcessWorkStatusRunner()
    let environment = ["HOME": folder.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"]
    #expect(runner.run(WorkStatusCommand(executable: git, arguments: ["-C", folder.path, "init", "-q", "-b", "feat/x"],
                                         environment: environment, timeout: 10)) == .succeeded(Data()))
    try Data("hello".utf8).write(to: folder.appendingPathComponent("new.txt"))
    let reader = WorkStatusReader(runner: runner, gate: WorkStatusGate(open: true), git: git, gh: nil, home: folder.path)
    let local = try #require(reader.local(folder.path))
    #expect(local.head == .branch("feat/x") && local.changed && local.commit == nil)
    #expect(reader.verdict(.branch(name: "feat/x", directory: folder.path, startedAt: 0, repository: nil)) == .uncommitted)
    #expect(reader.repository(folder.path) == .notOnGitHub)
    #expect(reader.local(FileManager.default.temporaryDirectory.path) == nil)
}
