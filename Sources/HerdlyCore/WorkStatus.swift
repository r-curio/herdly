import Foundation

/// How far a finished session's work got (#417, ADR 0023): a fact Herdly read from git and, through the
/// GitHub CLI, from the branch's pull request. It never judges the code. Anything Herdly cannot
/// establish is `none`, never a guess. Presentation only: no verdict orders the queue, counts as work,
/// acknowledges anything or touches a deadline.
public enum WorkStatus: String, CaseIterable, Equatable, Sendable {
    case none
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
        case .none: nil
        case .uncommitted: "uncommitted"
        case .notPushed: "not pushed"
        case .checksRunning: "checks running"
        case .checksFailing: "checks failing"
        case .conflict: "conflict"
        case .checksPassed: "checks passed"
        case .merged: "merged"
        }
    }

    /// Checks have finished or the work merged: nothing further happens on its own, so an Earlier row
    /// with one of these is not read again.
    public var isTerminal: Bool {
        switch self {
        case .checksFailing, .conflict, .checksPassed, .merged: true
        case .none, .uncommitted, .notPushed, .checksRunning: false
        }
    }
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
    }

    private(set) var entries: [AgentTurnIdentity: Entry] = [:]
    /// Cap on remembered turns; the oldest go first.
    public static let maximumTurns = 256

    public init() {}

    /// Records one scan's sightings. Two different sessions seen running in the same folder, or one
    /// inside the other, in the same scan mark both turns shared, for good.
    public mutating func observe(_ sightings: [WorkBranchSighting]) {
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
        for first in sightings {
            for second in sightings where first.turn.session != second.turn.session
                && Self.overlaps(first.directory, second.directory) {
                entries[first.turn]?.shared = true
            }
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
        guard !entry.shared, entry.directories.count == 1, entry.heads.count == 1,
              let directory = entry.directories.first, let head = entry.heads.first else { return .ambiguous }
        switch head {
        case .detached: return .detached(directory: directory)
        case .branch(let name):
            let repository: String? = if case .gitHub(let name) = entry.repository { name } else { nil }
            return .branch(name: name, directory: directory, startedAt: entry.startedAt, repository: repository)
        }
    }

    /// Turns on a named branch whose repository is still unread, with their folder.
    public var unreadRepositories: [(turn: AgentTurnIdentity, directory: String)] {
        entries.compactMap { turn, entry in
            guard entry.repository == .unread, !entry.shared, entry.directories.count == 1, entry.heads.count == 1,
                  case .branch? = entry.heads.first, let directory = entry.directories.first else { return nil }
            return (turn, directory)
        }.sorted { $0.directory < $1.directory }
    }

    /// Whether `directory` is the same as, or inside, a folder another running turn works in. A
    /// finished turn's folder is not read while other work runs there: what git sees then is not
    /// this turn's.
    public static func busy(_ directory: String, turn: AgentTurnIdentity, running: [WorkBranchSighting]) -> Bool {
        running.contains { $0.turn != turn && overlaps($0.directory, directory) }
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
    /// The branch has an upstream configured.
    public let hasUpstream: Bool
    /// Commits ahead of the upstream; nil without one, or when the upstream is gone.
    public let ahead: Int?
    /// Any changed, staged, conflicted or untracked file.
    public let changed: Bool
    /// Commits not on any remote: `ahead`, or a separate count when there is no upstream. Nil when
    /// it cannot be known (the upstream is gone, no remote exists, or the count failed).
    public var unpushed: Int?

    public init(head: GitHead, commit: String?, hasUpstream: Bool, ahead: Int?, changed: Bool, unpushed: Int? = nil) {
        self.head = head
        self.commit = commit
        self.hasUpstream = hasUpstream
        self.ahead = ahead
        self.changed = changed
        self.unpushed = unpushed ?? ahead
    }

    public static let maximumBytes = 1 << 20

    /// Parses porcelain v2 output. Every line must be a known header or entry; anything else, or a
    /// missing `branch.oid`/`branch.head`, is nil.
    public static func parse(status: String) -> GitLocalReading? {
        guard status.utf8.count <= maximumBytes else { return nil }
        var oid: String?, headName: String?, upstream = false, ahead: Int?, changed = false
        for raw in status.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("# ") {
                let parts = line.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid": oid = parts[1]
                case "branch.head": headName = parts[1]
                case "branch.upstream": upstream = !parts[1].isEmpty
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
        return GitLocalReading(head: head, commit: commit?.lowercased(), hasUpstream: upstream,
                               ahead: upstream ? ahead : nil, changed: changed)
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
    public enum Checks: Equatable, Sendable { case none, running, failing, passed, unknown }

    public let number: Int
    public let state: State
    public let mergedAt: Double?
    public let headCommit: String?
    public let mergeable: Mergeable
    public let checks: Checks

    public init(number: Int, state: State, mergedAt: Double? = nil, headCommit: String? = nil,
                mergeable: Mergeable = .unknown, checks: Checks = .none) {
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
    case none
    /// More than one open pull request for the branch: none is chosen.
    case ambiguous
    case found(GitHubPullRequest)
}

public enum GitHubPullRequestReader {
    /// The `--json` fields one `gh pr list` call asks for (docs/evidence/github-pr-status.md).
    public static let fields = "number,state,headRefName,headRefOid,isCrossRepository,mergedAt,mergeable,statusCheckRollup"
    public static let maximumBytes = 1 << 20

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
                guard let text = entry.mergedAt, let date = ISO8601DateFormatter().date(from: text) else { return .unavailable }
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
        return .none
    }

    /// One state for every check and status: any failure fails; otherwise anything unfinished runs;
    /// otherwise all passed. A value Herdly does not know makes the whole reading unknown.
    private static func checks(_ rollup: [Check]) -> GitHubPullRequest.Checks {
        guard !rollup.isEmpty else { return .none }
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

/// The furthest verdict that is certain, from the remembered branch and the latest readings.
public enum WorkStatusRule {
    /// - `local`: the folder's git reading, nil when it is not a work tree or the read failed.
    /// - `pullRequest`: the lookup for the remembered branch, nil when none was made.
    public static func verdict(branch: WorkBranch, local: GitLocalReading?,
                               pullRequest: GitHubPullRequestLookup?) -> WorkStatus {
        switch branch {
        case .unknown, .ambiguous:
            return .none
        case .detached:
            // No pull request for a detached HEAD, and no upstream to compare with.
            guard let local, case .detached = local.head, local.changed else { return .none }
            return .uncommitted
        case .branch(let name, _, _, _):
            let found: GitHubPullRequest? = if case .found(let request)? = pullRequest { request } else { nil }
            if let found, found.state == .merged { return .merged }
            // The folder may have moved on (an agent merged and went back to the default branch);
            // then git describes another branch and says nothing about this turn's.
            let matching = local.flatMap { $0.head == .branch(name) ? $0 : nil }
            if let matching {
                if matching.changed { return .uncommitted }
                guard let unpushed = matching.unpushed else { return .none }
                if unpushed > 0 { return .notPushed }
            }
            // Clean and pushed, or the folder has moved on to another branch: the open pull request
            // carries the work. An unreadable folder might hold uncommitted work, so only a merge,
            // which already happened, is certain without it.
            guard local != nil, let found, found.state == .open else { return .none }
            if found.mergeable == .conflicting { return .conflict }
            switch found.checks {
            case .failing: return .checksFailing
            case .running: return .checksRunning
            case .passed: return .checksPassed
            case .none, .unknown: return .none
            }
        }
    }
}

/// One verdict and when it was read.
public struct WorkStatusReading: Equatable, Sendable {
    public let verdict: WorkStatus
    public let readAt: Double
    /// When the turn's first reading was made; the refresh cap counts from here.
    public let firstReadAt: Double

    public init(verdict: WorkStatus, readAt: Double, firstReadAt: Double) {
        self.verdict = verdict
        self.readAt = readAt
        self.firstReadAt = firstReadAt
    }
}

/// When a finished turn is read again (#417). Bounded: checks running every 30 seconds, anything
/// else not yet settled every 2 minutes, never past an hour from the first reading, never again once
/// merged, and never for an Earlier row whose checks finished.
public enum WorkStatusSchedule {
    public static let runningInterval: Double = 30
    public static let settledInterval: Double = 120
    public static let cap: Double = 60 * 60

    public static func isDue(_ last: WorkStatusReading?, isEarlier: Bool, now: Double) -> Bool {
        guard let last else { return true }
        if last.verdict == .merged { return false }
        if isEarlier && last.verdict.isTerminal { return false }
        guard now - last.firstReadAt < cap else { return false }
        let interval = last.verdict == .checksRunning ? runningInterval : settledInterval
        return now - last.readAt >= interval
    }
}

// MARK: - GitHub CLI and the switch

/// The GitHub card's state (Paper "GitHub status in Agents"): the CLI's presence and sign-in.
public enum GitHubCLIStatus: Equatable, Sendable {
    case checking
    case notInstalled
    case signedOut(version: String?)
    case signedIn(version: String?)
    /// Installed, but its sign-in could not be read (offline, timed out, unreadable).
    case unknown(version: String?)

    public var subtitle: String {
        switch self {
        case .checking: "GitHub CLI"
        case .notInstalled: "GitHub CLI not installed"
        case .signedOut(let version): "\(Self.name(version)) · signed out"
        case .signedIn(let version): "\(Self.name(version)) · signed in to github.com"
        case .unknown(let version): "\(Self.name(version)) · sign-in unknown"
        }
    }

    public var header: AgentHeaderStatus {
        switch self {
        case .checking: .checking
        case .signedIn: .connected
        case .signedOut: .attention("Sign in required")
        case .notInstalled: .attention("Not installed")
        case .unknown: .attention("Status unknown")
        }
    }

    /// Whether the header's dot is gray rather than orange.
    public var isQuiet: Bool {
        switch self {
        case .checking, .notInstalled, .unknown: true
        case .signedIn, .signedOut: false
        }
    }

    private static func name(_ version: String?) -> String {
        version.map { "GitHub CLI \($0)" } ?? "GitHub CLI"
    }

    /// "gh version 2.62.0 (2024-11-14)" → "2.62.0".
    public static func version(_ output: String) -> String? {
        guard let line = output.split(separator: "\n").first, line.hasPrefix("gh version ") else { return nil }
        let value = line.dropFirst("gh version ".count).split(separator: " ").first.map(String.init) ?? ""
        guard !value.isEmpty, value.count <= 32,
              value.allSatisfy({ $0.isNumber || $0 == "." || $0.isLetter || $0 == "-" }) else { return nil }
        return value
    }

    /// `gh auth status --hostname github.com --json hosts`: signed in when the active github.com
    /// account's state is "success", signed out when github.com has no account, nil otherwise.
    public static func signedIn(_ data: Data) -> Bool? {
        struct Status: Decodable { let hosts: [String: [Account]] }
        struct Account: Decodable { let state: String; let active: Bool }
        guard data.count <= 64 * 1024, let status = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
        let accounts = status.hosts["github.com"] ?? []
        if accounts.isEmpty { return false }
        guard let active = accounts.first(where: \.active) else { return nil }
        return active.state == "success" ? true : nil
    }
}

/// The "Pull request status on finished rows" switch: the user's choice once made; until then on
/// only while `gh` is installed and signed in.
public enum WorkStatusSetting {
    public static let defaultsKey = "workStatusEnabled"

    public static func isOn(stored: Bool?, cli: GitHubCLIStatus) -> Bool {
        if let stored { return stored }
        if case .signedIn = cli { return true }
        return false
    }
}

/// Where Herdly looks for `git` and `gh`. The app does not inherit the shell's PATH. `/usr/bin/git` is
/// never used: without the developer tools it is a stub that offers to install them.
public enum WorkStatusTools {
    public static func git(home: String, isExecutable: (String) -> Bool) -> String? {
        ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
         "/Applications/Xcode.app/Contents/Developer/usr/bin/git"].first(where: isExecutable)
    }

    public static func gh(home: String, isExecutable: (String) -> Bool) -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(home)/.local/bin/gh", "/usr/bin/gh"].first(where: isExecutable)
    }
}
