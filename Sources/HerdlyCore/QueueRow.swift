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

    /// The gray source tag: which agent and, for Codex, which surface the row came from.
    public static func sourceTag(_ session: AgentSessionIdentity) -> String {
        switch (session.source, session.surface) {
        case (.claude, _): return "Claude"
        case (.codex, .desktop): return "Codex app"
        case (.codex, .cli): return "Codex CLI"
        }
    }

    /// The session's name without its source, which the tag already shows: the supplied name when
    /// known, otherwise the shortened identifier.
    public static func sessionName(_ session: AgentSessionIdentity, names: [AgentSessionIdentity: String] = [:]) -> String {
        if let name = names[session], !name.isEmpty { return name }
        return "session " + String(session.session.prefix(8)).lowercased()
    }

    /// The short tag after a row's session name saying what the row needs from the user, or nil for
    /// a running row, whose sprite step alone says it is working. A result keeps a failed, stopped,
    /// or unknown status in its tag so a failure never reads as a plain finish.
    public static func attentionTag(_ item: AgentAttentionItem) -> String? {
        switch item.kind {
        case .actionableApproval: return "approve"
        case .question: return "answer"
        case .handedBackApproval: return "handed back"
        case .waiting: return "waiting"
        case .statusUnavailable: return "status unknown"
        case .outcome, .earlierOutcome:
            switch item.outcome?.status {
            case .finished: return "check"
            case .failed: return "failed"
            case .stopped: return "stopped"
            case .unavailable, nil: return "status unknown"
            }
        case .running: return nil
        }
    }

    /// "project @ branch" for the identity line, from the session's working directory: the
    /// folder's last component and, when known, its checked-out branch. Nil without a directory.
    public static func place(directory: String?, branch: String?) -> String? {
        guard let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty else { return nil }
        let project = URL(fileURLWithPath: directory).lastPathComponent
        guard !project.isEmpty, project != "/" else { return nil }
        guard let branch, !branch.isEmpty else { return project }
        return "\(project) @ \(branch)"
    }
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
