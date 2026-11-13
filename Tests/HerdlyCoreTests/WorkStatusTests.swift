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
    #expect(reading.upstream == "origin/feat/x" && !reading.changed)
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
    #expect(gone?.upstream != nil && gone?.unpushed == nil && gone?.needsRemoteCount == false)
    // A worktree branch made from origin/main tracks main: being ahead of main is not "not pushed".
    let fromMain = GitLocalReading.parse(status: status(upstream: "origin/main", ahead: 5))
    #expect(fromMain?.unpushed == nil && fromMain?.needsRemoteCount == true)
    #expect(GitLocalReading.parse(status: status(upstream: nil, ahead: nil))?.needsRemoteCount == true)
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
    #expect(lookup([pr(state: "MERGED", mergedAt: "2026-11-11T04:43:51Z")], startedAt: startedAfter) == GitHubPullRequestLookup.noPullRequest)
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
    #expect(checks([]) == GitHubPullRequest.Checks.noChecks)
    #expect(checks([checkRun("SOMETHING_NEW")]) == .unknown)
    if case .found(let request) = lookup([pr(mergeable: "CONFLICTING")]) {
        #expect(request.mergeable == .conflicting)
    } else { Issue.record("expected a pull request") }
}

@Test func ghIgnoresForksOtherBranchesAndClosedPullRequests() {
    #expect(lookup([pr(fork: true)]) == GitHubPullRequestLookup.noPullRequest)
    #expect(lookup([pr(branch: "feat/other")]) == GitHubPullRequestLookup.noPullRequest)
    #expect(lookup([pr(state: "CLOSED")]) == GitHubPullRequestLookup.noPullRequest)
    #expect(lookup([]) == GitHubPullRequestLookup.noPullRequest)
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
    #expect(verdict(dirty, GitHubPullRequestLookup.noPullRequest) == .uncommitted)
    #expect(verdict(ahead, open(.passed)) == .notPushed)
    #expect(verdict(clean, open(.running)) == .checksRunning)
    #expect(verdict(clean, open(.failing)) == .checksFailing)
    #expect(verdict(clean, open(.passed, mergeable: .conflicting)) == .conflict)
    #expect(verdict(clean, open(.passed)) == .checksPassed)
    #expect(verdict(dirty, mergedPR) == .merged)
    #expect(verdict(clean, GitHubPullRequestLookup.noPullRequest) == WorkStatus.noVerdict)
    #expect(verdict(clean, open(.noChecks)) == WorkStatus.noVerdict)
    #expect(verdict(clean, open(.unknown)) == WorkStatus.noVerdict)
}

@Test func aFolderThatMovedOnSaysNothingAboutTheRememberedBranch() throws {
    // The agent merged and went back to main, where there are unrelated changes.
    let main = try #require(GitLocalReading.parse(status: status(head: "main", upstream: "origin/main",
                                                                  entries: ["? scratch.txt"])))
    #expect(WorkStatusRule.verdict(branch: feature, local: main, pullRequest: mergedPR) == .merged)
    #expect(WorkStatusRule.verdict(branch: feature, local: main, pullRequest: .unavailable) == WorkStatus.noVerdict)
    #expect(WorkStatusRule.verdict(branch: feature, local: main, pullRequest: open(.failing)) == .checksFailing)
    // A folder that cannot be read (deleted worktree, timeout) still shows a merge, but nothing open.
    #expect(WorkStatusRule.verdict(branch: feature, local: nil, pullRequest: mergedPR) == .merged)
    #expect(WorkStatusRule.verdict(branch: feature, local: nil, pullRequest: open(.passed)) == WorkStatus.noVerdict)
}

@Test func aMissingSignedOutOrFailingGhNeverGoesBeyondLocalGit() throws {
    let clean = try #require(GitLocalReading.parse(status: status()))
    let dirty = try #require(GitLocalReading.parse(status: status(entries: ["? a"])))
    let ahead = try #require(GitLocalReading.parse(status: status(ahead: 1)))
    for failed in [GitHubPullRequestLookup.unavailable, nil, .ambiguous] {
        #expect(WorkStatusRule.verdict(branch: feature, local: clean, pullRequest: failed) == WorkStatus.noVerdict)
        #expect(WorkStatusRule.verdict(branch: feature, local: dirty, pullRequest: failed) == .uncommitted)
        #expect(WorkStatusRule.verdict(branch: feature, local: ahead, pullRequest: failed) == .notPushed)
        #expect(WorkStatusRule.verdict(branch: feature, local: nil, pullRequest: failed) == WorkStatus.noVerdict)
    }
}

@Test func anUnknownUnpushedCountClaimsNothingPastIt() throws {
    let gone = try #require(GitLocalReading.parse(status: status(ahead: nil)))
    #expect(WorkStatusRule.verdict(branch: feature, local: gone, pullRequest: open(.passed)) == WorkStatus.noVerdict)
    #expect(WorkStatusRule.verdict(branch: feature, local: gone, pullRequest: mergedPR) == .merged)
}

@Test func uncertainBranchesAndDetachedHeadsGiveAtMostUncommitted() throws {
    let dirty = try #require(GitLocalReading.parse(status: status(entries: ["? a"])))
    let detachedDirty = try #require(GitLocalReading.parse(status: status(head: "(detached)", upstream: nil, ahead: nil,
                                                                           entries: ["? a"])))
    #expect(WorkStatusRule.verdict(branch: .unknown, local: dirty, pullRequest: mergedPR) == WorkStatus.noVerdict)
    #expect(WorkStatusRule.verdict(branch: .ambiguous, local: dirty, pullRequest: mergedPR) == WorkStatus.noVerdict)
    #expect(WorkStatusRule.verdict(branch: .detached(directory: "/w/repo"), local: detachedDirty, pullRequest: mergedPR)
        == .uncommitted)
    #expect(WorkStatusRule.verdict(branch: .detached(directory: "/w/repo"), local: dirty, pullRequest: nil) == WorkStatus.noVerdict)
}

// MARK: - Branch memory

private func presence(_ session: AgentSessionIdentity, _ turn: String?, _ directory: String) -> WorkPresence {
    WorkPresence(session: session, turn: turn, directory: directory)
}

private func sighting(_ turn: AgentTurnIdentity, _ directory: String = "/w/repo", _ head: GitHead? = .branch("feat/x"),
                      at startedAt: Double = 1_000) -> WorkBranchSighting {
    WorkBranchSighting(turn: turn, startedAt: startedAt, directory: directory, head: head)
}

@Test func theBranchSeenWhileTheTurnRanIsRemembered() {
    var memory = WorkBranchMemory()
    memory.observe([sighting(turnA)], at: 1_000)
    memory.record(.gitHub("o/repo"), for: turnA)
    #expect(memory.branch(for: turnA) == feature)
    #expect(memory.branch(for: turnB) == .unknown)
}

@Test func duplicateAndReorderedSightingsRememberTheSameBranch() {
    var forward = WorkBranchMemory(), backward = WorkBranchMemory()
    let scans = [[sighting(turnA, at: 1_005)], [sighting(turnA, at: 1_000)], [sighting(turnA, at: 1_000)],
                 [sighting(turnA, "/w/repo/", nil, at: 1_010)]]
    for scan in scans { forward.observe(scan, at: 1_000) }
    for scan in scans.reversed() { backward.observe(scan, at: 1_000) }
    #expect(forward == backward)
    #expect(forward.branch(for: turnA) == .branch(name: "feat/x", directory: "/w/repo", startedAt: 1_000, repository: nil))
}

@Test func aBranchChangedMidTurnHasNoVerdict() {
    var memory = WorkBranchMemory()
    memory.observe([sighting(turnA)], at: 1_000)
    memory.observe([sighting(turnA, "/w/repo", .branch("main"))], at: 1_000)
    #expect(memory.branch(for: turnA) == .ambiguous)
    var moved = WorkBranchMemory()
    moved.observe([sighting(turnA)], at: 1_000)
    moved.observe([sighting(turnA, "/w/other")], at: 1_000)
    #expect(moved.branch(for: turnA) == .ambiguous)
}

@Test func twoSessionsInOneFolderDuringTheTurnHaveNoVerdict() {
    var memory = WorkBranchMemory()
    memory.observe([sighting(turnA)], at: 1_000)
    memory.observe([sighting(turnA), sighting(turnB, "/w/repo/Sources")], at: 1_000)
    memory.observe([sighting(turnA)], at: 1_000)
    #expect(memory.branch(for: turnA) == .ambiguous)
    #expect(memory.branch(for: turnB) == .ambiguous)
    #expect(memory.unreadRepositories.isEmpty)
    // Two folders that only share a name prefix are not the same folder.
    var apart = WorkBranchMemory()
    apart.observe([sighting(turnA), sighting(turnB, "/w/repo-two")], at: 1_000)
    #expect(apart.branch(for: turnA) != .ambiguous)
}

@Test func oneSessionsNextTurnIsNotASecondSession() {
    var memory = WorkBranchMemory()
    memory.observe([sighting(turnA), sighting(turnA2)], at: 1_000)
    #expect(memory.branch(for: turnA) != .ambiguous)
}

@Test func aFinishedTurnIsNotReadWhileOtherWorkRunsInItsFolder() {
    #expect(WorkBranchMemory.busy("/w/repo", turn: turnA, present: [presence(sessionB, "t1", "/w/repo")]))
    #expect(WorkBranchMemory.busy("/w/repo", turn: turnA, present: [presence(sessionA, "t2", "/w/repo")]))
    #expect(!WorkBranchMemory.busy("/w/repo", turn: turnA, present: [presence(sessionB, "t1", "/w/elsewhere")]))
    // The same session's row naming no turn, or this turn itself, is not other work.
    #expect(!WorkBranchMemory.busy("/w/repo", turn: turnA, present: [presence(sessionA, nil, "/w/repo"),
                                                                     presence(sessionA, "t1", "/w/repo")]))
}

@Test func aDetachedHeadIsRememberedWithoutABranch() {
    var memory = WorkBranchMemory()
    memory.observe([sighting(turnA, "/w/repo", .detached("a6b1eae"))], at: 1_000)
    #expect(memory.branch(for: turnA) == .detached(directory: "/w/repo"))
    #expect(memory.unreadRepositories.isEmpty)
}

@Test func memoryKeepsOnlyRowsStillShownAndIsBounded() {
    var memory = WorkBranchMemory()
    memory.observe([sighting(turnA), sighting(turnB, "/w/b")], at: 1_000)
    memory.retain([turnB])
    #expect(memory.branch(for: turnA) == .unknown)
    var many = WorkBranchMemory()
    many.observe((0..<(WorkBranchMemory.maximumTurns + 10)).map { index in
        sighting(AgentTurnIdentity(session: sessionA, turn: "t\(index)"), "/w/\(index)", at: Double(index))
    }, at: 1_000)
    #expect(many.entries.count == WorkBranchMemory.maximumTurns)
    #expect(many.branch(for: AgentTurnIdentity(session: sessionA, turn: "t0")) == .unknown)
}

@Test func branchReaderTellsADetachedHeadFromABranch() {
    #expect(GitBranchReader.parseHead("ref: refs/heads/feat/x\n") == .branch("feat/x"))
    #expect(GitBranchReader.parseHead("A6B1EAE4F3C22FB3AE5CFD2A2D340710203FD0C4\n") == .detached("a6b1eae"))
    #expect(GitBranchReader.head("ref: refs/heads/main") == "main")
}

// MARK: - Refresh schedule

@Test func onlyRunningChecksAreReadAgainOnAFixedIntervalUntilTheCap() {
    let running = WorkStatusReading(verdict: .checksRunning, readAt: 100, firstReadAt: 100)
    #expect(WorkStatusSchedule.isDue(nil, now: 0))
    #expect(!WorkStatusSchedule.isDue(running, now: 129))
    #expect(WorkStatusSchedule.isDue(running, now: 130))
    let late = WorkStatusReading(verdict: .checksRunning, readAt: 100 + 3_590, firstReadAt: 100)
    #expect(!WorkStatusSchedule.isDue(late, now: 100 + WorkStatusSchedule.cap))
}

@Test func everyOtherVerdictIsTerminalAndNeverReadAgain() {
    for verdict in WorkStatus.allCases where verdict != .checksRunning {
        #expect(verdict.isTerminal)
        // Not even a "checks passed" row, to catch a later merge.
        #expect(!WorkStatusSchedule.isDue(WorkStatusReading(verdict: verdict, readAt: 100, firstReadAt: 100), now: 2_000))
    }
    #expect(!WorkStatus.checksRunning.isTerminal)
}

// MARK: - Batch selection

private func memory(_ sightings: [WorkBranchSighting], repositories: [AgentTurnIdentity: WorkRepository] = [:])
    -> WorkBranchMemory {
    var memory = WorkBranchMemory()
    memory.observe(sightings, at: 1_000)
    for (turn, repository) in repositories { memory.record(repository, for: turn) }
    return memory
}

@Test func aBatchReadsDueFinishedTurnsOnTheirRememberedBranch() {
    let remembered = memory([sighting(turnA)], repositories: [turnA: .gitHub("o/repo")])
    let batch = WorkStatusBatch.plan(finished: [turnA], present: [], memory: remembered, readings: [:], now: 2_000)
    #expect(batch == WorkStatusBatch(repositories: [], reads: [WorkStatusRead(turn: turnA, branch: feature)],
                                     settledNoVerdict: []))
    let read = WorkStatusReading(verdict: .checksPassed, readAt: 1_900, firstReadAt: 1_900)
    #expect(WorkStatusBatch.plan(finished: [turnA], present: [], memory: remembered, readings: [turnA: read], now: 2_000).isEmpty)
}

@Test func unknownAndAmbiguousTurnsSettleAsNoVerdictWithoutRunning() {
    let shared = memory([sighting(turnA), sighting(turnB, "/w/repo")])
    let batch = WorkStatusBatch.plan(finished: [turnA, turnA2], present: [], memory: shared, readings: [:], now: 2_000)
    #expect(batch.isEmpty)
    #expect(batch.settledNoVerdict == [turnA, turnA2])
    let settled = WorkStatusReading(verdict: .noVerdict, readAt: 2_000, firstReadAt: 2_000)
    #expect(WorkStatusBatch.plan(finished: [turnA], present: [], memory: shared, readings: [turnA: settled],
                                 now: 3_000).settledNoVerdict.isEmpty)
}

@Test func aBatchWaitsForTheRepositoryAndForABusyFolder() {
    let unread = memory([sighting(turnA)])
    let first = WorkStatusBatch.plan(finished: [turnA], present: [], memory: unread, readings: [:], now: 2_000)
    #expect(first.repositories == [WorkRepositoryRead(turn: turnA, directory: "/w/repo")])
    #expect(first.reads.isEmpty)
    let known = memory([sighting(turnA)], repositories: [turnA: .notOnGitHub])
    let busy = WorkStatusBatch.plan(finished: [turnA], present: [presence(sessionB, nil, "/w/repo/sub")], memory: known,
                                    readings: [:], now: 2_000)
    #expect(busy.isEmpty && busy.settledNoVerdict.isEmpty)
}

@Test func aBatchIsCappedAcrossRepositoriesAndReads() {
    let turns = (0..<10).map { AgentTurnIdentity(session: AgentSessionIdentity(source: .claude, sourceScope: "s",
                                                                               session: "s\($0)", surface: .cli), turn: "t") }
    var many = WorkBranchMemory()
    many.observe(turns.enumerated().map { sighting($1, "/w/\($0)") }, at: 1_000)
    for turn in turns.prefix(8) { many.record(.notOnGitHub, for: turn) }
    let batch = WorkStatusBatch.plan(finished: Array(turns.prefix(8)), present: [], memory: many, readings: [:], now: 0)
    #expect(batch.repositories.count == 2)
    #expect(batch.reads.count == WorkStatusBatch.limit - 2)
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
    #expect(GitHubCLIStatus.notInstalled.subtitle == "GitHub CLI not installed")
    #expect(GitHubCLIStatus.notInstalled.header == .unavailable("Not installed"))
    // Not a Paper frame: gray, and no switch shown as if connected.
    #expect(GitHubCLIStatus.unknown(version: "2.62.0").header == .unavailable("Status unknown"))
    #expect(!WorkStatusSetting.showsSwitch(stored: nil, cli: .unknown(version: nil)))
    // A choice once made keeps its switch in every state, so off can be turned back on.
    #expect(WorkStatusSetting.showsSwitch(stored: false, cli: .signedOut(version: nil)))
    #expect(WorkStatusSetting.showsSwitch(stored: false, cli: .notInstalled))
    #expect(WorkStatusSetting.showsSwitch(stored: false, cli: .signedIn(version: nil)))
    // Once the user turned it on, it can always be turned off.
    #expect(WorkStatusSetting.showsSwitch(stored: true, cli: .unknown(version: nil)))
}

@Test func theLastCheckIsRememberedWithoutAnAccountOrToken() {
    #expect(GitHubCLIStatus.signedIn(version: "2.62.0").remembered == "signedIn 2.62.0")
    #expect(GitHubCLIStatus.remembered("signedIn 2.62.0") == .signedIn(version: "2.62.0"))
    #expect(GitHubCLIStatus.remembered("signedOut ") == .signedOut(version: nil))
    #expect(GitHubCLIStatus.unknown(version: "1").remembered == nil && GitHubCLIStatus.notInstalled.remembered == nil)
    #expect(GitHubCLIStatus.remembered("signedIn 2.62.0 token") == nil)
    #expect(GitHubCLIStatus.remembered("admin 1.0") == nil && GitHubCLIStatus.remembered(nil) == nil)
    #expect(GitHubCLIStatus.withoutRunning(installed: false, remembered: .signedIn(version: "1")) == .notInstalled)
    #expect(GitHubCLIStatus.withoutRunning(installed: true, remembered: nil) == .unknown(version: nil))
    #expect(GitHubCLIStatus.withoutRunning(installed: true, remembered: .signedOut(version: "2")) == .signedOut(version: "2"))
    #expect(WorkStatusSetting.mayCheckCLI(stored: nil) && WorkStatusSetting.mayCheckCLI(stored: true))
    #expect(!WorkStatusSetting.mayCheckCLI(stored: false))
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
    #expect(WorkStatusTools.git(isExecutable: { $0 == "/usr/bin/git" }) == nil)
    #expect(WorkStatusTools.git(isExecutable: { _ in true }) == "/opt/homebrew/bin/git")
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

private func reader(_ runner: FakeRunner, open: Bool = true, cliGate: WorkStatusGate = WorkStatusGate(open: true),
                    gh: String? = "/opt/homebrew/bin/gh") -> WorkStatusReader {
    WorkStatusReader(runner: runner, gate: WorkStatusGate(open: open), cliGate: cliGate, git: "/opt/homebrew/bin/git",
                     gh: gh, home: "/h")
}

@Test func theReaderCombinesGitAndGhReadOnly() {
    let runner = FakeRunner(reply())
    let reader = reader(runner)
    #expect(reader.repository("/w/repo") == .gitHub("o/repo"))
    #expect(reader.verdict(feature).verdict == .checksFailing)
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
    #expect(reader.verdict(feature).verdict == WorkStatus.noVerdict)
    #expect(reader.repository("/w/repo") == .notOnGitHub)
    #expect(reader.verdict(.detached(directory: "/w/repo")).verdict == WorkStatus.noVerdict)
    #expect(runner.calls.isEmpty)
}

@Test func aTimedOutOrFailingGitCommandGivesNoVerdict() {
    let timedOut = FakeRunner { command in
        command.executable.hasSuffix("/gh") ? .succeeded(pullRequests([pr()])) : .timedOut
    }
    #expect(reader(timedOut).verdict(feature).verdict == WorkStatus.noVerdict)
    #expect(reader(timedOut).repository("/w/repo") == .notOnGitHub)
    let notATree = FakeRunner { _ in .failed(128) }
    #expect(reader(notATree).verdict(feature).verdict == WorkStatus.noVerdict)
}

@Test func aMissingOrFailingGhKeepsOnlyTheLocalVerdict() {
    let dirty = status(entries: ["? new.swift"])
    #expect(reader(FakeRunner(reply(status: dirty)), gh: nil).verdict(feature).verdict == .uncommitted)
    for failure in [WorkStatusCommandResult.failed(1), .timedOut, .notLaunched, .tooLarge, .succeeded(Data("<html>".utf8))] {
        #expect(reader(FakeRunner(reply(gh: failure))).verdict(feature).verdict == WorkStatus.noVerdict)
        #expect(reader(FakeRunner(reply(status: dirty, gh: failure))).verdict(feature).verdict == .uncommitted)
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
    #expect(reader(runner).verdict(feature).verdict == .notPushed)
    let pushedFromMain = FakeRunner { command in
        if command.executable.hasSuffix("/gh") { return .succeeded(pullRequests([pr()])) }
        if command.arguments.contains("status") { return .succeeded(Data(status(upstream: "origin/main", ahead: 3).utf8)) }
        if command.arguments.contains("remote") { return .succeeded(Data("origin\n".utf8)) }
        if command.arguments.contains("rev-list") { return .succeeded(Data("0\n".utf8)) }
        return .failed(1)
    }
    #expect(reader(pushedFromMain).verdict(feature).verdict == .checksPassed)
    let noRemote = FakeRunner { command in
        if command.arguments.contains("status") { return .succeeded(Data(status(upstream: nil, ahead: nil).utf8)) }
        if command.arguments.contains("remote") { return .succeeded(Data()) }
        return .failed(1)
    }
    #expect(reader(noRemote).verdict(feature).verdict == WorkStatus.noVerdict)
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

private func defaults(_ stored: Bool?) throws -> (UserDefaults, String) {
    let suite = "herdly-work-status-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    if let stored { defaults.set(stored, forKey: WorkStatusSetting.defaultsKey) }
    return (defaults, suite)
}

@MainActor @Test func theModelRunsNothingWhileTheSwitchIsOff() async throws {
    let (defaults, suite) = try defaults(false)
    defer { defaults.removePersistentDomain(forName: suite) }
    let runner = FakeRunner(reply())
    let gate = WorkStatusGate(open: true)
    let model = makeModel(runner, gate: gate, defaults: defaults)
    #expect(!gate.isOpen)
    #expect(model.scanned([item(running: turnA)], heads: ["/w/repo": .branch("feat/x")], directory: { _ in "/w/repo" },
                          now: 1_000) == nil)
    #expect(model.scanned([item(finished: turnA)], heads: [:], directory: { _ in "/w/repo" }, now: 1_100) == nil)
    #expect(runner.calls.isEmpty)
    #expect(model.verdict(for: turnA) == WorkStatus.noVerdict)
}

@MainActor @Test func theCardRunsNoGhWhileTheSwitchIsOff() async throws {
    let (defaults, suite) = try defaults(false)
    defer { defaults.removePersistentDomain(forName: suite) }
    let runner = FakeRunner { _ in .succeeded(Data("gh version 2.62.0\n".utf8)) }
    let gate = WorkStatusGate(open: false)
    // No check remembered: installed on disk reads unknown, with no switch and nothing run.
    let model = makeModel(runner, gate: gate, defaults: defaults)
    #expect(model.cli == .unknown(version: nil))
    #expect(model.refreshCLI() == nil)
    #expect(model.cli == .unknown(version: nil) && !model.mayCheckCLI)
    // A remembered check is shown as it was; a missing binary is found on disk.
    defaults.set("signedIn 2.62.0", forKey: WorkStatusSetting.rememberedCLIKey)
    #expect(model.refreshCLI() == nil)
    #expect(model.cli == .signedIn(version: "2.62.0") && model.showsSwitch && !model.isEnabled)
    let missing = makeModel(runner, gate: gate, defaults: defaults, gh: nil)
    #expect(missing.cli == .notInstalled)
    #expect(runner.calls.isEmpty)
}

@MainActor @Test func turningTheSwitchOnChecksGhAgainAndRemembersTheResult() async throws {
    let (defaults, suite) = try defaults(false)
    defer { defaults.removePersistentDomain(forName: suite) }
    let signedOut = #"{"hosts":{}}"#
    let runner = FakeRunner { command in
        command.arguments == ["--version"] ? .succeeded(Data("gh version 2.62.0 (2024-11-14)\n".utf8))
            : .succeeded(Data(signedOut.utf8))
    }
    let gate = WorkStatusGate(open: false)
    let model = makeModel(runner, gate: gate, defaults: defaults)
    #expect(runner.calls.isEmpty)
    let check = try #require(model.setEnabled(true))
    await check.value
    #expect(runner.calls.map(\.arguments.first) == ["--version", "auth"])
    #expect(model.cli == .signedOut(version: "2.62.0"))
    #expect(defaults.string(forKey: WorkStatusSetting.rememberedCLIKey) == "signedOut 2.62.0")
    // The user's choice stands; the switch stays so it can be turned off again.
    #expect(model.isEnabled && gate.isOpen && model.showsSwitch)
}

@MainActor @Test func theModelReadsAFinishedTurnOnItsRememberedBranch() async throws {
    let (defaults, suite) = try defaults(true)
    defer { defaults.removePersistentDomain(forName: suite) }
    let runner = FakeRunner(reply())
    let gate = WorkStatusGate(open: false)
    let model = makeModel(runner, gate: gate, defaults: defaults)
    #expect(gate.isOpen)
    let repository = try #require(model.scanned([item(running: turnA)], heads: ["/w/repo": .branch("feat/x")],
                                                directory: { _ in "/w/repo" }, now: 1_000))
    await repository.value
    #expect(model.memory.unreadRepositories.isEmpty)
    let read = try #require(model.scanned([item(finished: turnA)], heads: [:], directory: { _ in "/w/repo" }, now: 1_100))
    await read.value
    #expect(model.verdict(for: turnA) == .checksFailing)
    #expect(model.readings[turnA] == WorkStatusReading(verdict: .checksFailing, readAt: 1_100, firstReadAt: 1_100))
    // A terminal verdict is not read again.
    #expect(model.scanned([item(finished: turnA)], heads: [:], directory: { _ in "/w/repo" }, now: 9_000) == nil)
    // Nothing is read while the switch is off, and what was read is forgotten.
    let before = runner.calls.count
    model.setEnabled(false)
    #expect(model.scanned([item(finished: turnA)], heads: [:], directory: { _ in "/w/repo" }, now: 9_100) == nil)
    #expect(runner.calls.count == before)
    #expect(model.verdict(for: turnA) == WorkStatus.noVerdict)
}

/// A model whose reader shares its two gates.
@MainActor private func makeModel(_ runner: FakeRunner, gate: WorkStatusGate, defaults: UserDefaults,
                                  gh: String? = "/opt/homebrew/bin/gh") -> WorkStatusModel {
    let cliGate = WorkStatusGate(open: false)
    return WorkStatusModel(reader: reader(runner, gh: gh).with(gate: gate, cliGate: cliGate), gate: gate, cliGate: cliGate,
                           defaults: defaults)
}

private extension WorkStatusReader {
    func with(gate: WorkStatusGate, cliGate: WorkStatusGate) -> WorkStatusReader {
        WorkStatusReader(runner: runner, gate: gate, cliGate: cliGate, git: git, gh: gh, home: home)
    }
}

// MARK: - The real runner

// Wall-clock margins on purpose: a real process past a real deadline is the only way to test that the
// runner kills it and stops its reader; everything above runs on explicit clocks.

@Test func theProcessRunnerStopsACommandPastItsWait() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-work-status-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let script = folder.appendingPathComponent("slow")
    // `exec`, so terminating the command ends the sleep too and no orphan holds a pipe other tests read.
    try Data("#!/bin/sh\nexec sleep 5\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let started = Date()
    let result = ProcessWorkStatusRunner().run(WorkStatusCommand(executable: script.path, arguments: [],
                                                                 environment: [:], timeout: 0.3))
    #expect(result == .timedOut)
    #expect(Date().timeIntervalSince(started) < 5)
    #expect(ProcessWorkStatusRunner().run(WorkStatusCommand(executable: folder.appendingPathComponent("none").path,
                                                            arguments: [], environment: [:], timeout: 1)) == .notLaunched)
}

// The commands' own sleeps are 5 s: longer than any bound asserted here. The lock holder sleeps 30 s so
// only a kill can free its lock early.

/// Runs `body` as a shell script after starting a descendant that keeps the command's stdout open and
/// holds an exclusive lock on a file until it dies. Nothing is killed by pid afterwards: the runner's
/// group kill is what ends the descendant, and `released` reports whether the lock came free, which
/// only the descendant's death can cause (a lock cannot be confused with a reused pid).
/// `held` says the descendant had taken its lock before the run returned, so `released` means something.
private func runHoldingStdout(_ body: String, timeout: Double) throws
    -> (result: WorkStatusCommandResult, seconds: Double, held: Bool, released: Bool) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-work-status-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let lock = folder.appendingPathComponent("lock").path, marker = folder.appendingPathComponent("locked").path
    let holder = #"use Fcntl ":flock"; open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; "#
        + #"open(my $m, ">", $ARGV[1]) or die; close $m; sleep 30"#
    let script = folder.appendingPathComponent("holds")
    try Data("""
    #!/bin/sh
    /usr/bin/perl -e '\(holder)' '\(lock)' '\(marker)' &
    while [ ! -f '\(marker)' ]; do sleep 0.05; done
    \(body)

    """.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let started = Date()
    let result = ProcessWorkStatusRunner().run(WorkStatusCommand(executable: script.path, arguments: [],
                                                                 environment: [:], timeout: timeout))
    let seconds = Date().timeIntervalSince(started)
    let held = FileManager.default.fileExists(atPath: marker)
    // The kernel frees the lock as the holder exits. The holder sleeps 30 s, so a release within the
    // 10 s allowed here (generous for a loaded test machine) can only come from the group kill.
    let descriptor = open(lock, O_RDWR)
    defer { if descriptor >= 0 { close(descriptor) } }
    var released = false
    for _ in 0..<500 where descriptor >= 0 {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { released = true; break }
        usleep(20_000)
    }
    return (result, seconds, held, released)
}

@Test func aChildHoldingStdoutCannotKeepARunWaitingAndDiesWithTheGroup() throws {
    // Deadlines leave the descendant time to take its lock first, even on a loaded machine. The time
    // bound only shows the run did not wait for the holder's 30 s sleep to end its output.
    // The command itself is still running at its deadline.
    let slow = try runHoldingStdout("sleep 5", timeout: 3)
    #expect(slow.held && slow.result == .timedOut && slow.seconds < 10 && slow.released)
    // It ignores SIGTERM, so SIGKILL ends it.
    let stubborn = try runHoldingStdout("trap '' TERM\nwhile :; do sleep 1; done", timeout: 3)
    #expect(stubborn.held && stubborn.result == .timedOut && stubborn.seconds < 10 && stubborn.released)
    // It exited, but its output never ended: incomplete, and the descendant is killed with the group.
    let exited = try runHoldingStdout("echo partial\nexit 0", timeout: 4)
    #expect(exited.held && exited.result == .timedOut && exited.seconds < 10 && exited.released)
}

// MARK: - Pending readings, live sessions in a folder and the card gate

@Test func gitHubStillWorkingItOutIsPending() throws {
    let clean = try #require(GitLocalReading.parse(status: status()))
    let main = try #require(GitLocalReading.parse(status: status(head: "main", upstream: "origin/main")))
    func result(_ local: GitLocalReading?, _ lookup: GitHubPullRequestLookup?) -> WorkStatusResult {
        WorkStatusRule.result(branch: feature, local: local, pullRequest: lookup)
    }
    // Mergeability still being computed: the checks verdict stands, but a conflict may yet appear.
    #expect(result(clean, open(.passed, mergeable: .unknown)) == WorkStatusResult(.checksPassed, pending: true))
    #expect(result(clean, open(.failing, mergeable: .unknown)) == WorkStatusResult(.checksFailing, pending: true))
    // No checks registered yet.
    #expect(result(clean, open(.noChecks)) == WorkStatusResult(.noVerdict, pending: true))
    // Pushed, but the pull request is not listed yet.
    #expect(result(clean, .noPullRequest) == WorkStatusResult(.noVerdict, pending: true))
    // Settled readings.
    #expect(result(clean, open(.passed)) == WorkStatusResult(.checksPassed))
    #expect(result(clean, open(.passed, mergeable: .conflicting)) == WorkStatusResult(.conflict))
    #expect(result(main, .noPullRequest) == WorkStatusResult(.noVerdict))
    #expect(result(clean, .unavailable) == WorkStatusResult(.noVerdict))
    #expect(result(nil, .noPullRequest) == WorkStatusResult(.noVerdict))
    #expect(result(clean, mergedPR) == WorkStatusResult(.merged))
}

@Test func aPendingReadingIsReadAgainOnlyWithinItsGrace() {
    let pending = WorkStatusReading(verdict: .checksPassed, pending: true, readAt: 100, firstReadAt: 100)
    #expect(!WorkStatusSchedule.isDue(pending, now: 129))
    #expect(WorkStatusSchedule.isDue(pending, now: 130))
    let late = WorkStatusReading(verdict: .noVerdict, pending: true, readAt: 360, firstReadAt: 100)
    #expect(WorkStatusSchedule.isDue(late, now: 399))
    let settled = WorkStatusReading(verdict: .noVerdict, pending: true, readAt: 380, firstReadAt: 100)
    // Five minutes after the first reading it settles on what it has.
    #expect(!WorkStatusSchedule.isDue(settled, now: 100 + WorkStatusSchedule.pendingGrace))
}

@Test func aSessionWaitingOnAnApprovalInTheFolderMakesItShared() {
    var memory = WorkBranchMemory()
    memory.observe([sighting(turnA)], present: [presence(sessionB, "t9", "/w/repo")], at: 1_000)
    #expect(memory.branch(for: turnA) == .ambiguous)
    var alone = WorkBranchMemory()
    alone.observe([sighting(turnA)], present: [presence(sessionA, "t1", "/w/repo"), presence(sessionB, nil, "/w/other")], at: 1_000)
    #expect(alone.branch(for: turnA) != .ambiguous)
}

private func item(approval session: AgentSessionIdentity, turn: String) -> AgentAttentionItem {
    let approval = AgentApproval(session: session, turn: turn, call: "c1", arrivedAt: 1_000)
    return AgentAttentionItem(id: .approval(approval.id), kind: .actionableApproval, session: session, arrivedAt: 1_000,
                              approval: approval, question: nil, outcome: nil, running: nil, unavailableReason: nil)
}

@MainActor @Test func theModelGivesNoVerdictWhenAnotherSessionWaitsOnAnApprovalInTheFolder() async throws {
    let (defaults, suite) = try defaults(true)
    defer { defaults.removePersistentDomain(forName: suite) }
    let runner = FakeRunner(reply())
    let model = makeModel(runner, gate: WorkStatusGate(open: false), defaults: defaults)
    model.scanned([item(running: turnA), item(approval: sessionB, turn: "t1")], heads: ["/w/repo": .branch("feat/x")],
                  directory: { _ in "/w/repo" }, now: 1_000)
    #expect(model.memory.branch(for: turnA) == .ambiguous)
    #expect(model.scanned([item(finished: turnA)], heads: [:], directory: { _ in "/w/repo" }, now: 1_100) == nil)
    #expect(model.readings[turnA]?.verdict == WorkStatus.noVerdict)
    #expect(!runner.calls.contains { $0.arguments.contains("status") || $0.executable.hasSuffix("/gh") })
}

@MainActor @Test func aPendingVerdictIsReadAgainThenSettles() async throws {
    let (defaults, suite) = try defaults(true)
    defer { defaults.removePersistentDomain(forName: suite) }
    // GitHub has not computed mergeability yet.
    let runner = FakeRunner(reply(gh: .succeeded(pullRequests([pr(mergeable: "UNKNOWN")]))))
    let model = makeModel(runner, gate: WorkStatusGate(open: false), defaults: defaults)
    await model.scanned([item(running: turnA)], heads: ["/w/repo": .branch("feat/x")], directory: { _ in "/w/repo" },
                        now: 1_000)?.value
    await model.scanned([item(finished: turnA)], heads: [:], directory: { _ in "/w/repo" }, now: 1_100)?.value
    #expect(model.readings[turnA] == WorkStatusReading(verdict: .checksPassed, pending: true, readAt: 1_100, firstReadAt: 1_100))
    let again = try #require(model.scanned([item(finished: turnA)], heads: [:], directory: { _ in "/w/repo" }, now: 1_130))
    await again.value
    #expect(model.readings[turnA]?.readAt == 1_130)
    #expect(model.scanned([item(finished: turnA)], heads: [:], directory: { _ in "/w/repo" },
                          now: 1_100 + WorkStatusSchedule.pendingGrace) == nil)
    #expect(model.verdict(for: turnA) == .checksPassed)
}

@MainActor @Test func aSwitchTurnedOffWhileSignedOutCanBeTurnedBackOn() async throws {
    let (defaults, suite) = try defaults(true)
    defer { defaults.removePersistentDomain(forName: suite) }
    let runner = FakeRunner { command in
        command.arguments == ["--version"] ? .succeeded(Data("gh version 2.62.0\n".utf8))
            : .succeeded(Data(#"{"hosts":{}}"#.utf8))
    }
    let model = makeModel(runner, gate: WorkStatusGate(open: false), defaults: defaults)
    await model.refreshCLI()?.value
    #expect(model.cli == .signedOut(version: "2.62.0"))
    model.setEnabled(false)
    #expect(model.showsSwitch && !model.mayCheckCLI)
    let before = runner.calls.count
    let check = try #require(model.setEnabled(true))
    await check.value
    #expect(runner.calls.count == before + 2)
    #expect(model.isEnabled && model.showsSwitch)
}

@Test func turningTheSwitchOffBetweenCardCommandsStopsTheSecond() {
    let cliGate = WorkStatusGate(open: true)
    let runner = FakeRunner { command in
        // The switch goes off while `gh --version` runs.
        if command.arguments == ["--version"] { cliGate.set(false) }
        return .succeeded(Data("gh version 2.62.0\n".utf8))
    }
    #expect(reader(runner, cliGate: cliGate).cliStatus() == .unknown(version: "2.62.0"))
    #expect(runner.calls.map(\.arguments) == [["--version"]])
    #expect(reader(runner, cliGate: WorkStatusGate(open: false)).cliStatus() == .unknown(version: nil))
    #expect(runner.calls.count == 1)
}

// MARK: - Turns waiting on a request

@Test func aSessionInAnApprovalForAnothersWholeRunIsSharedToo() {
    // A never shows a running row while B runs; both are marked.
    var memory = WorkBranchMemory()
    memory.observe([sighting(turnB)], present: [presence(sessionA, "t1", "/w/repo")], at: 1_000)
    memory.observe([sighting(turnA)], at: 1_000)
    #expect(memory.branch(for: turnA) == .ambiguous)
    #expect(memory.branch(for: turnB) == .ambiguous)
    // The other way round.
    var reversed = WorkBranchMemory()
    reversed.observe([sighting(turnA)], present: [presence(sessionB, "t1", "/w/repo")], at: 1_000)
    reversed.observe([sighting(turnB)], at: 1_000)
    #expect(reversed.branch(for: turnA) == .ambiguous)
    #expect(reversed.branch(for: turnB) == .ambiguous)
    // A presence alone remembers no branch.
    var waitingOnly = WorkBranchMemory()
    waitingOnly.observe([], present: [presence(sessionA, "t1", "/w/repo"), presence(sessionB, "t1", "/w/repo")], at: 1_000)
    #expect(waitingOnly.branch(for: turnA) == .unknown)
}

@Test func anEmptyTurnNameIsNoTurn() {
    #expect(WorkPresence(session: sessionA, turn: "", directory: "/w").turn == nil)
    #expect(WorkPresence(session: sessionA, turn: "", directory: "/w").turnIdentity == nil)
    #expect(WorkPresence(session: sessionA, turn: "t1", directory: "/w").turnIdentity == turnA)
    #expect(item(approval: sessionB, turn: "t1").turn == "t1")
    #expect(item(finished: turnA).turn == "t1")
}

@MainActor private func scan(_ model: WorkStatusModel, _ items: [AgentAttentionItem], head: GitHead? = nil,
                             now: Double) async {
    await model.scanned(items, heads: head.map { ["/w/repo": $0] } ?? [:], directory: { _ in "/w/repo" }, now: now)?.value
}

@MainActor @Test func aTurnInAnApprovalKeepsItsSharedMarkAndBranchHistory() async throws {
    let (defaults, suite) = try defaults(true)
    defer { defaults.removePersistentDomain(forName: suite) }
    let feat = GitHead.branch("feat/x")

    // Shared while A waited on an approval: B ran in the folder, then A ran on alone and finished.
    let shared = makeModel(FakeRunner(reply()), gate: WorkStatusGate(open: false), defaults: defaults)
    await scan(shared, [item(running: turnA)], head: feat, now: 1_000)
    await scan(shared, [item(approval: sessionA, turn: "t1"), item(running: turnB)], head: feat, now: 1_010)
    await scan(shared, [item(running: turnA)], head: feat, now: 1_020)
    await scan(shared, [item(finished: turnA)], now: 1_030)
    #expect(shared.memory.branch(for: turnA) == .ambiguous)
    #expect(shared.verdict(for: turnA) == WorkStatus.noVerdict)

    // The branch changed across the approval.
    let changed = makeModel(FakeRunner(reply()), gate: WorkStatusGate(open: false), defaults: defaults)
    await scan(changed, [item(running: turnA)], head: feat, now: 1_000)
    await scan(changed, [item(approval: sessionA, turn: "t1")], now: 1_010)
    await scan(changed, [item(running: turnA)], head: .branch("main"), now: 1_020)
    await scan(changed, [item(finished: turnA)], now: 1_030)
    #expect(changed.memory.branch(for: turnA) == .ambiguous)

    // Finishing straight from an approval still resolves on the remembered branch.
    let direct = makeModel(FakeRunner(reply()), gate: WorkStatusGate(open: false), defaults: defaults)
    await scan(direct, [item(running: turnA)], head: feat, now: 1_000)
    await scan(direct, [item(approval: sessionA, turn: "t1")], now: 1_010)
    #expect(direct.memory.branch(for: turnA) == feature)
    await scan(direct, [item(finished: turnA)], now: 1_020)
    #expect(direct.verdict(for: turnA) == .checksFailing)
}

@Test func aTurnSeenOnlyWaitingIsEvictedByWhenItWasFirstSeen() {
    var memory = WorkBranchMemory()
    // Seen only in requests, sharing a folder, at time 1: the oldest turns remembered.
    memory.observe([], present: [presence(sessionA, "t1", "/w/repo"), presence(sessionB, "t1", "/w/repo")], at: 1)
    #expect(memory.entries[turnA]?.startedAt == 1)
    memory.observe((0..<WorkBranchMemory.maximumTurns).map { index in
        sighting(AgentTurnIdentity(session: sessionA, turn: "n\(index)"), "/w/n\(index)", at: 100 + Double(index))
    }, at: 400)
    #expect(memory.entries.count == WorkBranchMemory.maximumTurns)
    #expect(memory.entries[turnA] == nil && memory.entries[turnB] == nil)
}

@Test func aSightingIsAPresenceInItsFolder() {
    #expect(WorkPresence(sighting(turnA)) == presence(sessionA, "t1", "/w/repo"))
}
