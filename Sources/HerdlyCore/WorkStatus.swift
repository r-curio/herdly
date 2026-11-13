import Foundation

/// How far a finished session's work got (#417, ADR 0024): a fact Herdly read from git and, through the
/// GitHub CLI, from the branch's pull request. It never judges the code. Anything Herdly cannot
/// establish is `noVerdict`, never a guess. Presentation only: no verdict orders the queue, counts as work,
/// acknowledges anything or touches a deadline.
public enum WorkStatus: String, CaseIterable, Equatable, Sendable {
    case noVerdict
    case uncommitted
    case notPushed
    case checksRunning
    case checksFailing
    case conflict
    case checksPassed
    case merged

    /// The state words the row shows (agreed 2026-11-13); nil for no verdict.
    public var words: String? {
        switch self {
        case .noVerdict: nil
        case .uncommitted: "uncommitted"
        case .notPushed: "not pushed"
        case .checksRunning: "checks running"
        case .checksFailing: "checks failing"
        case .conflict: "conflict"
        case .checksPassed: "checks passed"
        case .merged: "merged"
        }
    }

    /// Every verdict but checks running is terminal for refresh: only running checks are read again
    /// on a schedule. A "checks passed" row is not re-read to catch a later merge.
    public var isTerminal: Bool { self != .checksRunning }
}

/// What a work tree's HEAD names: a branch, or a detached commit (shortened to seven characters).
public enum GitHead: Hashable, Sendable {
    case branch(String)
    case detached(String)

    /// The row's place text: the branch name, or the shortened commit.
    public var label: String {
        switch self {
        case .branch(let name): name
        case .detached(let commit): commit
        }
    }
}

// MARK: - Branch memory

/// One scan's sighting of a running turn: where it works and what HEAD named there at that scan.
public struct WorkBranchSighting: Equatable, Sendable {
    public let turn: AgentTurnIdentity
    public let startedAt: Double
    public let directory: String
    /// Nil when the HEAD could not be read on this scan; that is no information, not a change.
    public let head: GitHead?

    public init(turn: AgentTurnIdentity, startedAt: Double, directory: String, head: GitHead?) {
        self.turn = turn
        self.startedAt = startedAt
        self.directory = directory
        self.head = head
    }
}

/// The branch a finished turn's verdict is about, as remembered from while it ran.
public enum WorkBranch: Equatable, Sendable {
    /// Herdly never saw the turn running with a readable HEAD.
    case unknown
    /// The branch or folder changed mid-turn, or another session worked in the same folder.
    case ambiguous
    case detached(directory: String)
    /// `repository` is GitHub's "owner/name" from the folder's `origin`, nil while unread or when the
    /// folder is not on GitHub.
    case branch(name: String, directory: String, startedAt: Double, repository: String?)

    /// The folder git reads, nil when there is nothing to read.
    public var directory: String? {
        switch self {
        case .unknown, .ambiguous: nil
        case .detached(let directory), .branch(_, let directory, _, _): directory
        }
    }

    /// The pull request lookup to make: only for a named branch whose repository is on GitHub.
    public var pullRequestQuery: (repository: String, branch: String, startedAt: Double)? {
        guard case .branch(let name, _, let startedAt, let repository?) = self else { return nil }
        return (repository, name, startedAt)
    }
}

/// A live session's folder on one scan: running, waiting, or holding an approval, question or
/// handed-back request. Any of these working in a folder makes it shared or busy.
public struct WorkPresence: Equatable, Sendable {
    public let session: AgentSessionIdentity
    /// The turn when the row names one; nil when it does not (an empty name is none).
    public let turn: String?
    public let directory: String

    public init(session: AgentSessionIdentity, turn: String?, directory: String) {
        self.session = session
        self.turn = turn.flatMap { $0.isEmpty ? nil : $0 }
        self.directory = directory
    }

    /// A running turn's sighting as a presence in its folder.
    public init(_ sighting: WorkBranchSighting) {
        self.init(session: sighting.turn.session, turn: sighting.turn.turn, directory: sighting.directory)
    }

    /// The turn this row is about, when it names one.
    public var turnIdentity: AgentTurnIdentity? {
        turn.map { AgentTurnIdentity(session: session, turn: $0) }
    }
}

/// Where a turn's GitHub repository stands: read once while the turn runs.
public enum WorkRepository: Equatable, Sendable {
    case unread
    /// `origin` is not a GitHub repository, or the folder has none: no GitHub call is made.
    case notOnGitHub
    case gitHub(String)
}

/// Per session and turn, the folder and branch Herdly saw while the turn ran (#417). Memory only:
/// a restart forgets it, so restored rows have no verdict. Every sighting is merged as a set, so
/// duplicate and reordered sightings remember the same thing.
public struct WorkBranchMemory: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var directories: Set<String>
        var heads: Set<GitHead>
        var startedAt: Double
        var shared: Bool
        var repository: WorkRepository

        /// The one folder and HEAD seen throughout the turn, nil when it was shared, moved, changed
        /// branch, or never had a readable HEAD.
        var single: (directory: String, head: GitHead)? {
            guard !shared, directories.count == 1, heads.count == 1,
                  let directory = directories.first, let head = heads.first else { return nil }
            return (directory, head)
        }
    }

    private(set) var entries: [AgentTurnIdentity: Entry] = [:]
    /// Cap on remembered turns; the oldest go first.
    public static let maximumTurns = 256

    public init() {}

    /// Records one scan's sightings, made at `now`. A different live session seen in the same folder, or
    /// one inside the other, in the same scan marks the turn shared, for good. `present` holds every live
    /// session on that scan (running, waiting, approval, question or handed-back request).
    public mutating func observe(_ sightings: [WorkBranchSighting], present: [WorkPresence] = [], at now: Double) {
        for sighting in sightings {
            let directory = Self.normalized(sighting.directory)
            guard !directory.isEmpty else { continue }
            var entry = entries[sighting.turn] ?? Entry(directories: [], heads: [], startedAt: sighting.startedAt,
                                                         shared: false, repository: .unread)
            entry.directories.insert(directory)
            if let head = sighting.head { entry.heads.insert(head) }
            entry.startedAt = min(entry.startedAt, sighting.startedAt)
            entries[sighting.turn] = entry
        }
        let everyone = present + sightings.map(WorkPresence.init)
        // Both sides of an overlap are marked, whether or not that turn was seen running: a turn that
        // sat in an approval or question while another session worked in its folder is shared too.
        for member in everyone {
            guard let turn = member.turnIdentity, everyone.contains(where: {
                $0.session != member.session && Self.overlaps($0.directory, member.directory)
            }) else { continue }
            if entries[turn] == nil {
                let directory = Self.normalized(member.directory)
                // No HEAD yet: the turn reads unknown until a sighting, and ambiguous after one. It dates
                // from when it was first seen, so the cap evicts it by age like any other turn.
                entries[turn] = Entry(directories: directory.isEmpty ? [] : [directory], heads: [],
                                      startedAt: now, shared: true, repository: .unread)
            }
            entries[turn]?.shared = true
        }
        if entries.count > Self.maximumTurns {
            let oldest = entries.sorted { $0.value.startedAt < $1.value.startedAt }.prefix(entries.count - Self.maximumTurns)
            for (turn, _) in oldest { entries[turn] = nil }
        }
    }

    /// The repository read for a turn's folder; only a turn still unread takes it.
    public mutating func record(_ repository: WorkRepository, for turn: AgentTurnIdentity) {
        guard entries[turn]?.repository == .unread else { return }
        entries[turn]?.repository = repository
    }

    /// Drops every turn not in `turns`.
    public mutating func retain(_ turns: Set<AgentTurnIdentity>) {
        entries = entries.filter { turns.contains($0.key) }
    }

    public func branch(for turn: AgentTurnIdentity) -> WorkBranch {
        guard let entry = entries[turn], !entry.heads.isEmpty else { return .unknown }
        guard let (directory, head) = entry.single else { return .ambiguous }
        switch head {
        case .detached: return .detached(directory: directory)
        case .branch(let name):
            let repository: String? = if case .gitHub(let name) = entry.repository { name } else { nil }
            return .branch(name: name, directory: directory, startedAt: entry.startedAt, repository: repository)
        }
    }

    /// Turns on a named branch whose repository is still unread, with their folder.
    public var unreadRepositories: [WorkRepositoryRead] {
        entries.compactMap { turn, entry in
            guard entry.repository == .unread, let (directory, head) = entry.single, case .branch = head else { return nil }
            return WorkRepositoryRead(turn: turn, directory: directory)
        }.sorted { ($0.directory, $0.turn.turn) < ($1.directory, $1.turn.turn) }
    }

    /// Whether `directory` is the same as, or inside, a folder where other live work is: another
    /// session, or this session's other turn. A finished turn's folder is not read then: what git sees
    /// is not this turn's. A row of the same session that names no turn (a handed-back request kept
    /// after its turn) does not count.
    public static func busy(_ directory: String, turn: AgentTurnIdentity, present: [WorkPresence]) -> Bool {
        present.contains { other in
            guard overlaps(other.directory, directory) else { return false }
            if other.session != turn.session { return true }
            guard let otherTurn = other.turn else { return false }
            return otherTurn != turn.turn
        }
    }

    static func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return "" }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }

    static func overlaps(_ first: String, _ second: String) -> Bool {
        let first = normalized(first), second = normalized(second)
        guard !first.isEmpty, !second.isEmpty else { return false }
        func inside(_ child: String, _ parent: String) -> Bool {
            child == parent || child.hasPrefix(parent == "/" ? "/" : parent + "/")
        }
        return inside(first, second) || inside(second, first)
    }
}

// MARK: - Local git

/// One read of a work tree from `git status --porcelain=v2 --branch` (and, without an upstream, a
/// count of commits on no remote). No network.
public struct GitLocalReading: Equatable, Sendable {
    public let head: GitHead
    /// HEAD's full commit; nil before the first commit.
    public let commit: String?
    /// The configured upstream ("origin/feat/x"), nil without one.
    public let upstream: String?
    /// Commits ahead of the upstream; nil without one, or when the upstream branch is gone.
    public let ahead: Int?
    /// Any changed, staged, conflicted or untracked file.
    public let changed: Bool
    /// Commits not on any remote. `ahead` when the upstream is this branch's own remote branch;
    /// otherwise a separate count (`needsRemoteCount`). Nil when it cannot be known: the upstream
    /// branch is gone, no remote exists, or the count failed.
    public var unpushed: Int?

    public init(head: GitHead, commit: String?, upstream: String?, ahead: Int?, changed: Bool, unpushed: Int? = nil) {
        self.head = head
        self.commit = commit
        self.upstream = upstream
        self.ahead = ahead
        self.changed = changed
        self.unpushed = unpushed ?? (Self.tracksOwnBranch(head: head, upstream: upstream) ? ahead : nil)
    }

    /// A branch whose upstream is another branch (a worktree made from `origin/main`) or that has
    /// none is compared with every remote instead: ahead of `main` is not "not pushed". A branch
    /// whose own upstream is gone (deleted after a merge) is left unknown.
    public var needsRemoteCount: Bool {
        guard case .branch = head, commit != nil, unpushed == nil else { return false }
        guard upstream != nil else { return true }
        return !Self.tracksOwnBranch(head: head, upstream: upstream)
    }

    static func tracksOwnBranch(head: GitHead, upstream: String?) -> Bool {
        guard case .branch(let name) = head, let upstream else { return false }
        return upstream.hasSuffix("/" + name)
    }

    public static let maximumBytes = 1 << 20

    /// Parses porcelain v2 output. Every line must be a known header or entry; anything else, or a
    /// missing `branch.oid`/`branch.head`, is nil.
    public static func parse(status: String) -> GitLocalReading? {
        guard status.utf8.count <= maximumBytes else { return nil }
        var oid: String?, headName: String?, upstream: String?, ahead: Int?, changed = false
        for raw in status.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("# ") {
                let parts = line.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid": oid = parts[1]
                case "branch.head": headName = parts[1]
                case "branch.upstream": upstream = parts[1].isEmpty ? nil : parts[1]
                case "branch.ab":
                    let counts = parts[1].split(separator: " ")
                    guard counts.count == 2, counts[0].hasPrefix("+"), counts[1].hasPrefix("-"),
                          let value = Int(counts[0].dropFirst()), value >= 0, Int(counts[1].dropFirst()) != nil
                    else { return nil }
                    ahead = value
                default: continue
                }
            } else if ["1 ", "2 ", "u ", "? "].contains(where: line.hasPrefix) {
                changed = true
            } else {
                return nil
            }
        }
        guard let oid, let headName, !headName.isEmpty else { return nil }
        let commit: String? = oid == "(initial)" ? nil : oid
        if let commit, !(commit.count >= 7 && commit.allSatisfy(\.isHexDigit)) { return nil }
        let head: GitHead
        if headName == "(detached)" {
            guard let commit else { return nil }
            head = .detached(String(commit.prefix(7)).lowercased())
        } else {
            head = .branch(headName)
        }
        return GitLocalReading(head: head, commit: commit?.lowercased(), upstream: upstream,
                               ahead: upstream == nil ? nil : ahead, changed: changed)
    }

    /// A `git rev-list --count` result: one non-negative integer.
    public static func parseCount(_ output: String) -> Int? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 12, let value = Int(trimmed), value >= 0 else { return nil }
        return value
    }
}

/// GitHub's "owner/name" from a remote URL. Credentials and anything else in the URL are dropped;
/// a host other than github.com is not GitHub.
public enum GitHubRepositoryName {
    public static func parse(remoteURL: String) -> String? {
        let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, url.count <= 2_048, !url.contains("\n") else { return nil }
        var path: Substring
        if let scheme = url.range(of: "://") {
            let kind = url[..<scheme.lowerBound].lowercased()
            guard ["https", "http", "ssh", "git"].contains(kind) else { return nil }
            let rest = url[scheme.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let authority = rest[..<slash]
            let host = (authority.split(separator: "@").last ?? "").split(separator: ":").first ?? ""
            guard host.lowercased() == "github.com" else { return nil }
            path = rest[rest.index(after: slash)...]
        } else if let colon = url.firstIndex(of: ":") {
            let host = url[..<colon].split(separator: "@").last ?? ""
            guard host.lowercased() == "github.com" else { return nil }
            path = url[url.index(after: colon)...]
        } else {
            return nil
        }
        while path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && part != "." && part != ".." && part.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
        }) else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}

// MARK: - GitHub pull requests

public struct GitHubPullRequest: Equatable, Sendable {
    public enum State: Equatable, Sendable { case open, merged, closed }
    public enum Mergeable: Equatable, Sendable { case mergeable, conflicting, unknown }
    public enum Checks: Equatable, Sendable { case noChecks, running, failing, passed, unknown }

    public let number: Int
    public let state: State
    public let mergedAt: Double?
    public let headCommit: String?
    public let mergeable: Mergeable
    public let checks: Checks

    public init(number: Int, state: State, mergedAt: Double? = nil, headCommit: String? = nil,
                mergeable: Mergeable = .unknown, checks: Checks = .noChecks) {
        self.number = number
        self.state = state
        self.mergedAt = mergedAt
        self.headCommit = headCommit
        self.mergeable = mergeable
        self.checks = checks
    }
}

/// The pull request for a remembered branch, as read through `gh pr list`.
public enum GitHubPullRequestLookup: Equatable, Sendable {
    /// `gh` missing, signed out, offline, rate-limited, failed, timed out, or printed something unreadable.
    case unavailable
    case noPullRequest
    /// More than one open pull request for the branch: none is chosen.
    case ambiguous
    case found(GitHubPullRequest)
}

public enum GitHubPullRequestReader {
    /// The `--json` fields one `gh pr list` call asks for (docs/evidence/github-pr-status.md).
    public static let fields = "number,state,headRefName,headRefOid,isCrossRepository,mergedAt,mergeable,statusCheckRollup"
    public static let maximumBytes = 1 << 20
    /// GitHub's `mergedAt`, such as "2026-11-11T04:43:51Z". A value type, so one is shared.
    private static let timestamp = Date.ISO8601FormatStyle()

    /// The arguments for the one read: every state, so a merged pull request whose branch was deleted
    /// is still found.
    public static func arguments(repository: String, branch: String) -> [String] {
        ["pr", "list", "--repo", repository, "--head", branch, "--state", "all", "--limit", "20", "--json", fields]
    }

    private struct Entry: Decodable {
        let number: Int
        let state: String
        let headRefName: String
        let headRefOid: String?
        let isCrossRepository: Bool
        let mergedAt: String?
        let mergeable: String?
        let statusCheckRollup: [Check]?
    }

    private struct Check: Decodable {
        let typename: String?
        let status: String?
        let conclusion: String?
        let state: String?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename", status, conclusion, state
        }
    }

    /// The branch's pull request: its one open pull request, otherwise the latest one merged at or
    /// after `turnStartedAt` (a merge from before the turn is not this turn's work). Pull requests
    /// from forks, for other branches, or closed without merging are ignored.
    public static func parse(_ data: Data, branch: String, turnStartedAt: Double) -> GitHubPullRequestLookup {
        guard data.count <= maximumBytes, let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return .unavailable
        }
        var requests: [GitHubPullRequest] = []
        for entry in entries where entry.headRefName == branch && !entry.isCrossRepository {
            let state: GitHubPullRequest.State
            switch entry.state {
            case "OPEN": state = .open
            case "MERGED": state = .merged
            case "CLOSED": state = .closed
            default: return .unavailable
            }
            var mergedAt: Double?
            if state == .merged {
                guard let text = entry.mergedAt, let date = try? Date(text, strategy: Self.timestamp) else { return .unavailable }
                mergedAt = date.timeIntervalSince1970
            }
            let mergeable: GitHubPullRequest.Mergeable = switch entry.mergeable {
            case "MERGEABLE": .mergeable
            case "CONFLICTING": .conflicting
            default: .unknown
            }
            requests.append(GitHubPullRequest(number: entry.number, state: state, mergedAt: mergedAt,
                                              headCommit: entry.headRefOid?.lowercased(), mergeable: mergeable,
                                              checks: checks(entry.statusCheckRollup ?? [])))
        }
        let open = requests.filter { $0.state == .open }
        if open.count > 1 { return .ambiguous }
        if let request = open.first { return .found(request) }
        let merged = requests.filter { $0.state == .merged && ($0.mergedAt ?? -.infinity) >= turnStartedAt }
        if let latest = merged.max(by: { ($0.mergedAt ?? 0) < ($1.mergedAt ?? 0) }) { return .found(latest) }
        return .noPullRequest
    }

    /// One state for every check and status: any failure fails; otherwise anything unfinished runs;
    /// otherwise all passed. A value Herdly does not know makes the whole reading unknown.
    private static func checks(_ rollup: [Check]) -> GitHubPullRequest.Checks {
        guard !rollup.isEmpty else { return .noChecks }
        var failing = false, running = false, unknown = false
        for check in rollup {
            switch check.typename {
            case "CheckRun":
                if check.status != "COMPLETED" {
                    if ["QUEUED", "IN_PROGRESS", "WAITING", "PENDING", "REQUESTED"].contains(check.status ?? "") {
                        running = true
                    } else { unknown = true }
                    continue
                }
                switch check.conclusion {
                case "SUCCESS", "NEUTRAL", "SKIPPED": break
                case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": failing = true
                default: unknown = true
                }
            case "StatusContext":
                switch check.state {
                case "SUCCESS": break
                case "PENDING", "EXPECTED": running = true
                case "FAILURE", "ERROR": failing = true
                default: unknown = true
                }
            default:
                unknown = true
            }
        }
        if failing { return .failing }
        if unknown { return .unknown }
        return running ? .running : .passed
    }
}

// MARK: - The verdict

/// The pull request a verdict was read from, as a finished row names it (#418): "herdly#431".
public struct WorkPullRequest: Equatable, Sendable {
    /// GitHub's "owner/name", from the remembered branch's `origin`.
    public let repository: String
    public let number: Int

    public init(repository: String, number: Int) {
        self.repository = repository
        self.number = number
    }

    /// The repository's name without its owner, as the row shows it.
    public var name: String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }
}

/// What a finished row says about its work (#418): a verdict, and the pull request it came from when
/// a pull request decided it. Only a verdict other than `noVerdict` makes one.
public struct WorkStatusLabel: Equatable, Sendable {
    public let verdict: WorkStatus
    public let pullRequest: WorkPullRequest?

    public init(verdict: WorkStatus, pullRequest: WorkPullRequest? = nil) {
        self.verdict = verdict
        self.pullRequest = pullRequest
    }
}

/// A verdict, and whether GitHub was still working it out when it was read.
public struct WorkStatusResult: Equatable, Sendable {
    public let verdict: WorkStatus
    /// GitHub had not finished: an open pull request whose mergeability is still being computed or
    /// whose checks have not registered, or a pushed branch whose pull request is not listed yet.
    /// Read again within `WorkStatusSchedule.pendingGrace`.
    public let pending: Bool
    /// The pull request that decided the verdict (merged, conflict, or a checks verdict); nil when git
    /// decided it, there is no verdict, or the branch's repository is unknown.
    public let pullRequest: WorkPullRequest?

    public init(_ verdict: WorkStatus, pending: Bool = false, pullRequest: WorkPullRequest? = nil) {
        self.verdict = verdict
        self.pending = pending
        self.pullRequest = verdict == .noVerdict ? nil : pullRequest
    }
}

/// The furthest verdict that is certain, from the remembered branch and the latest readings.
public enum WorkStatusRule {
    public static func verdict(branch: WorkBranch, local: GitLocalReading?,
                               pullRequest: GitHubPullRequestLookup?) -> WorkStatus {
        result(branch: branch, local: local, pullRequest: pullRequest).verdict
    }

    /// - `local`: the folder's git reading, nil when it is not a work tree, the read failed, or there
    ///   was nothing to read.
    /// - `pullRequest`: the lookup for the remembered branch, nil when none was made.
    public static func result(branch: WorkBranch, local: GitLocalReading?,
                              pullRequest: GitHubPullRequestLookup?) -> WorkStatusResult {
        switch branch {
        case .unknown, .ambiguous:
            return WorkStatusResult(.noVerdict)
        case .detached:
            // No pull request for a detached HEAD, and no upstream to compare with.
            guard let local, case .detached = local.head, local.changed else { return WorkStatusResult(.noVerdict) }
            return WorkStatusResult(.uncommitted)
        case .branch(let name, _, _, let repository):
            let found: GitHubPullRequest? = if case .found(let request)? = pullRequest { request } else { nil }
            let named = found.flatMap { request in repository.map { WorkPullRequest(repository: $0, number: request.number) } }
            if let found, found.state == .merged { return WorkStatusResult(.merged, pullRequest: named) }
            // The folder may have moved on (an agent merged and went back to the default branch);
            // then git describes another branch and says nothing about this turn's.
            let matching = local.flatMap { $0.head == .branch(name) ? $0 : nil }
            if let matching {
                if matching.changed { return WorkStatusResult(.uncommitted) }
                guard let unpushed = matching.unpushed else { return WorkStatusResult(.noVerdict) }
                if unpushed > 0 { return WorkStatusResult(.notPushed) }
            }
            // Clean and pushed, or the folder has moved on to another branch: the open pull request
            // carries the work. An unreadable folder might hold uncommitted work, so only a merge,
            // which already happened, is certain without it.
            guard local != nil else { return WorkStatusResult(.noVerdict) }
            guard let found, found.state == .open else {
                // Pushed, but GitHub may not list the pull request yet.
                return WorkStatusResult(.noVerdict, pending: matching != nil && pullRequest == .noPullRequest)
            }
            let computing = found.mergeable == .unknown || found.checks == .noChecks
            if found.mergeable == .conflicting { return WorkStatusResult(.conflict, pullRequest: named) }
            let verdict: WorkStatus = switch found.checks {
            case .failing: .checksFailing
            case .running: .checksRunning
            case .passed: .checksPassed
            case .noChecks, .unknown: .noVerdict
            }
            return WorkStatusResult(verdict, pending: computing, pullRequest: named)
        }
    }
}

/// One verdict and when it was read.
public struct WorkStatusReading: Equatable, Sendable {
    public let verdict: WorkStatus
    /// GitHub was still working it out (`WorkStatusResult.pending`).
    public let pending: Bool
    /// The pull request that decided the verdict (`WorkStatusResult.pullRequest`).
    public let pullRequest: WorkPullRequest?
    public let readAt: Double
    /// When the turn's first reading was made; the refresh cap and pending grace count from here.
    public let firstReadAt: Double

    /// A live row of the turn's own came back after it was read: the verdict no longer holds and reads
    /// none, but the reading keeps its times, so a re-read stays inside the original cap and interval.
    public let isWithdrawn: Bool

    public init(verdict: WorkStatus, pending: Bool = false, pullRequest: WorkPullRequest? = nil, readAt: Double,
                firstReadAt: Double, isWithdrawn: Bool = false) {
        self.verdict = verdict
        self.pending = pending
        self.pullRequest = verdict == .noVerdict ? nil : pullRequest
        self.readAt = readAt
        self.firstReadAt = firstReadAt
        self.isWithdrawn = isWithdrawn
    }

    /// One fresh result read at `readAt`.
    public init(_ result: WorkStatusResult, readAt: Double, firstReadAt: Double) {
        self.init(verdict: result.verdict, pending: result.pending, pullRequest: result.pullRequest, readAt: readAt,
                  firstReadAt: firstReadAt)
    }

    /// This reading with its verdict withdrawn and its times kept.
    public var withdrawn: WorkStatusReading {
        WorkStatusReading(verdict: .noVerdict, readAt: readAt, firstReadAt: firstReadAt, isWithdrawn: true)
    }

    /// What the row shows: nil without a verdict.
    public var label: WorkStatusLabel? {
        verdict == .noVerdict ? nil : WorkStatusLabel(verdict: verdict, pullRequest: pullRequest)
    }
}

/// When a finished turn is read (#417): once when it first appears, then again only while its checks
/// run, every 30 seconds, never past an hour from the first reading. A reading GitHub had not finished
/// (`pending`) is read again at the same interval for 5 minutes from the first reading, then settles
/// on what it has. Every other verdict is terminal, so no row, recent or Earlier, is re-read for it.
public enum WorkStatusSchedule {
    public static let runningInterval: Double = 30
    public static let pendingGrace: Double = 5 * 60
    public static let cap: Double = 60 * 60

    public static func isDue(_ last: WorkStatusReading?, now: Double) -> Bool {
        guard let last else { return true }
        let age = now - last.firstReadAt
        let refreshing = last.isWithdrawn || !last.verdict.isTerminal || (last.pending && age < pendingGrace)
        guard refreshing, age < cap else { return false }
        return now - last.readAt >= runningInterval
    }
}

/// A folder whose `origin` is read for a running turn.
public struct WorkRepositoryRead: Equatable, Sendable {
    public let turn: AgentTurnIdentity
    public let directory: String

    public init(turn: AgentTurnIdentity, directory: String) {
        self.turn = turn
        self.directory = directory
    }
}

/// A finished turn read on its remembered branch.
public struct WorkStatusRead: Equatable, Sendable {
    public let turn: AgentTurnIdentity
    public let branch: WorkBranch

    public init(turn: AgentTurnIdentity, branch: WorkBranch) {
        self.turn = turn
        self.branch = branch
    }
}

/// What one scan reads (#417), chosen without running anything.
public struct WorkStatusBatch: Equatable, Sendable {
    /// Running turns' repositories still unread.
    public let repositories: [WorkRepositoryRead]
    /// Finished turns due a reading.
    public let reads: [WorkStatusRead]
    /// Finished turns to set to no verdict without running anything, because their branch is unknown or
    /// ambiguous. Includes a turn that already has a verdict: if its branch changed after the reading,
    /// that verdict would be a guess. Turns that already read no verdict are left out.
    public let settledNoVerdict: [AgentTurnIdentity]
    /// Finished turns whose reading is withdrawn because a live row of their own came back (#426). They
    /// read no verdict until those rows end, then are read again within the original cap.
    public let dropped: [AgentTurnIdentity]

    public var isEmpty: Bool { repositories.isEmpty && reads.isEmpty }

    /// Most commands' worth of turns in one batch, so a long queue cannot start a burst.
    public static let limit = 6

    /// - `finished`: finished rows' turns in queue order.
    /// - `present`: this scan's live sessions, for the busy-folder rule.
    public static func plan(finished: [AgentTurnIdentity], present: [WorkPresence], memory: WorkBranchMemory,
                            readings: [AgentTurnIdentity: WorkStatusReading], now: Double,
                            limit: Int = limit) -> WorkStatusBatch {
        let unread = memory.unreadRepositories
        let repositories = Array(unread.prefix(limit))
        let waiting = Set(unread.map(\.turn))
        var reads: [WorkStatusRead] = [], settled: [AgentTurnIdentity] = [], dropped: [AgentTurnIdentity] = []
        for turn in finished {
            let branch = memory.branch(for: turn)
            guard let folder = branch.directory else {
                // Unknown or ambiguous: no verdict, without running anything.
                if readings[turn]?.verdict != .noVerdict || readings[turn]?.pending == true { settled.append(turn) }
                continue
            }
            // This turn's own work can go on after it finished: a background subagent working, or one
            // paused on an approval or question that can resume (#426). Until every such row ends the
            // turn is not read, and a reading it already has no longer holds.
            if present.contains(where: { $0.turnIdentity == turn }) {
                if let reading = readings[turn], !reading.isWithdrawn { dropped.append(turn) }
                continue
            }
            // Another turn working there changes what git sees; a repository not yet read would make
            // this reading skip GitHub.
            guard !WorkBranchMemory.busy(folder, turn: turn, present: present), !waiting.contains(turn) else { continue }
            guard reads.count + repositories.count < limit,
                  WorkStatusSchedule.isDue(readings[turn], now: now) else { continue }
            reads.append(WorkStatusRead(turn: turn, branch: branch))
        }
        return WorkStatusBatch(repositories: repositories, reads: reads, settledNoVerdict: settled, dropped: dropped)
    }
}
