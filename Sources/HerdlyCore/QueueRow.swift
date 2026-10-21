import Foundation

/// The readings an open-queue row shows beside its title: how long ago its latest evidence
/// arrived, which agent surface it came from, and where the session works. Every value is
/// presentation only; none identifies a navigation target or proves anything about the session.
public enum QueueRowPresentation {
    /// A compact age for the row's trailing lane: "<1m", "4m", "2h", "3d". A clock that runs
    /// backwards reads as "<1m" rather than a negative age.
    public static func age(since start: Double, now: Double) -> String {
        let seconds = max(0, now - start)
        if seconds < 60 { return "<1m" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    /// The same age read aloud by VoiceOver, where "<1m" and "4m" would be spelled out.
    public static func spokenAge(since start: Double, now: Double) -> String {
        let seconds = max(0, now - start)
        func unit(_ count: Int, _ name: String) -> String { "Updated \(count) \(name)\(count == 1 ? "" : "s") ago" }
        if seconds < 60 { return "Updated less than a minute ago" }
        if seconds < 3_600 { return unit(Int(seconds / 60), "minute") }
        if seconds < 86_400 { return unit(Int(seconds / 3_600), "hour") }
        return unit(Int(seconds / 86_400), "day")
    }

    /// The session's name without its source: the supplied name when known, otherwise the shortened
    /// identifier.
    public static func sessionName(_ session: AgentSessionIdentity, names: [AgentSessionIdentity: String] = [:]) -> String {
        if let name = names[session], !name.isEmpty { return name }
        return "session " + String(session.session.prefix(8)).lowercased()
    }

    /// The one word a row carries when it is off its normal path (D17), or nil. Approve, answer, and
    /// check are said by the row's section heading, and a stopped result is a normal end, so none of
    /// them gets a word; a working row's sprite step says it is working.
    public static func exception(_ item: AgentAttentionItem) -> RowException? {
        switch item.kind {
        case .handedBackApproval: return .handedBack
        case .waiting: return .waiting
        case .statusUnavailable: return .statusUnknown
        case .outcome, .earlierOutcome:
            switch item.outcome?.status {
            case .failed: return .failed
            case .unavailable, nil: return .statusUnknown
            case .finished, .stopped: return nil
            }
        case .actionableApproval, .question, .running: return nil
        }
    }

    /// The row's state in full, as VoiceOver reads it after the name: the reading the visual word
    /// and section heading shorten.
    public static func spokenState(_ item: AgentAttentionItem) -> String {
        let agent = item.session.source == .claude ? "Claude" : "Codex"
        switch item.kind {
        case .actionableApproval: return item.session.source == .claude ? "Claude permission needed" : "Permission needed"
        case .handedBackApproval: return "Continue in \(agent)"
        case .question: return item.session.source == .claude ? "Claude waiting" : "Codex needs an answer"
        case .outcome, .earlierOutcome:
            let label = switch item.outcome?.status {
            case .finished: "finished"
            case .failed: "failed"
            case .stopped: "stopped"
            case .unavailable, nil: "status unavailable"
            }
            return "\(agent) \(label)"
        case .statusUnavailable: return "Claude status unavailable"
        case .waiting: return "Waiting"
        case .running: return "Working"
        }
    }

    /// A row's spoken heading: name, place, any row note, the full state, and a live approval's
    /// seconds left. Parts Herdly does not have are left out; the state is always read.
    public static func spokenHeading(_ item: AgentAttentionItem, name: String, place: String?, note: RowNote?,
                                     countdown: ApprovalCountdown?) -> String {
        [name, place, note?.text, spokenState(item), countdown?.spoken].compactMap { $0 }.joined(separator: ", ")
    }

    /// The trailing age lane. A status-unavailable row has no arrival time (it is dated to the
    /// moment the queue is read), so it shows a dash rather than a misleading "<1m".
    public static func rowAge(_ item: AgentAttentionItem, now: Double) -> RowAge {
        guard item.kind != .statusUnavailable else { return RowAge(text: "—", spoken: "No update time") }
        return RowAge(text: age(since: item.lastUpdate, now: now), spoken: spokenAge(since: item.lastUpdate, now: now))
    }

    /// "Ns left" for a live approval, from its own window; nil for every other row. Display only:
    /// it reads the deadline and never moves it.
    public static func countdown(_ item: AgentAttentionItem, now: Double) -> ApprovalCountdown? {
        guard item.kind == .actionableApproval, let approval = item.approval else { return nil }
        return ApprovalCountdown(arrivedAt: approval.arrivedAt, expiresAt: approval.expiresAt, now: now)
    }

    /// The place after a row's name, from the session's working directory: the folder's last
    /// component, its checked-out branch, or both, as `format` asks. A part Herdly has not seen is
    /// left out, so Branch only without a branch shows nothing. Nil without a directory.
    public static func place(directory: String?, branch: String?, format: QueueLabelFormat = .repoAtBranch) -> String? {
        guard let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty else { return nil }
        let project = URL(fileURLWithPath: directory).lastPathComponent
        guard !project.isEmpty, project != "/" else { return nil }
        let branch = branch.flatMap { $0.isEmpty ? nil : $0 }
        switch format {
        case .repoOnly: return project
        case .branchOnly: return branch
        case .repoAtBranch: return branch.map { "\(project) @ \($0)" } ?? project
        }
    }
}

/// A queue row's single off-path word (D17). Only a failure is drawn in the red well (D14); the
/// others are plain dim text.
public enum RowException: Equatable, Sendable {
    case failed
    case handedBack
    case waiting
    case statusUnknown

    public var word: String {
        switch self {
        case .failed: "Failed"
        case .handedBack: "Handed back"
        case .waiting: "Waiting"
        case .statusUnknown: "Status unknown"
        }
    }

    public var isFailure: Bool { self == .failed }
}

/// The age lane's visible and spoken readings.
public struct RowAge: Equatable, Sendable {
    public let text: String
    public let spoken: String

    public init(text: String, spoken: String) {
        self.text = text
        self.spoken = spoken
    }
}

/// How much of a live approval's own window is left at `now` (D7, D12): whole seconds, rounded up
/// so "0s" appears only at the deadline, and the remaining share of `expiresAt - arrivedAt` for the
/// pill's bar. Never negative, never above one; a zero-length or unreadable window reads empty.
public struct ApprovalCountdown: Equatable, Sendable {
    public let seconds: Int
    public let fraction: Double

    public init(seconds: Int, fraction: Double) {
        self.seconds = seconds
        self.fraction = fraction
    }

    public init(arrivedAt: Double, expiresAt: Double, now: Double) {
        let remaining = expiresAt - now
        guard remaining.isFinite, remaining > 0 else {
            self.init(seconds: 0, fraction: 0)
            return
        }
        let window = expiresAt - arrivedAt
        let fraction = window.isFinite && window > 0 ? min(1, remaining / window) : 0
        self.init(seconds: Int(min(remaining.rounded(.up), Double(Int32.max))), fraction: fraction)
    }

    public var label: String { "\(seconds)s left" }
    public var spoken: String { "\(seconds) \(seconds == 1 ? "second" : "seconds") left" }
}

/// Reads the checked-out branch of the git work tree containing a directory, from `.git/HEAD`
/// alone: no git process, no network, nothing written. A linked worktree's `.git` file is
/// followed to its own HEAD. Symlinked or irregular files, oversized HEADs, and anything that
/// does not parse read as nil, so a row simply shows no branch.
public enum GitBranchReader {
    /// HEAD and `.git` files are a single short line; anything larger is not one.
    static let maximumBytes = 1_024
    /// Ancestors searched for `.git` before giving up.
    static let maximumDepth = 32

    public static func branch(forDirectory path: String) -> String? {
        var directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        for _ in 0..<maximumDepth {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                let gitDirectory = isDirectory.boolValue ? dotGit : linkedGitDirectory(dotGit, workTree: directory)
                return gitDirectory.flatMap { read($0.appendingPathComponent("HEAD")) }.flatMap(head)
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
        return nil
    }

    /// The branch named by HEAD's contents: `ref: refs/heads/<name>` gives the name; a detached
    /// HEAD gives its commit shortened to seven characters. Anything else is nil.
    public static func head(_ contents: String) -> String? {
        let line = contents.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let prefix = "refs/heads/"
            guard ref.hasPrefix(prefix), ref.count > prefix.count else { return nil }
            return String(ref.dropFirst(prefix.count))
        }
        guard line.count >= 7, line.allSatisfy(\.isHexDigit) else { return nil }
        return String(line.prefix(7)).lowercased()
    }

    /// A linked worktree's `.git` file reads `gitdir: <path>`, relative to the work tree or absolute.
    static func linkedGitDirectory(_ file: URL, workTree: URL) -> URL? {
        guard let contents = read(file),
              let line = contents.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true)
            : workTree.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }

    static func read(_ url: URL) -> String? {
        guard let (file, size) = CodexUsageReader.regularFile(url) else { return nil }
        defer { try? file.close() }
        guard size <= maximumBytes, let data = try? file.read(upToCount: maximumBytes) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
