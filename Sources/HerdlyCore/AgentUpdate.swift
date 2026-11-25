import Foundation

/// The app a version problem row's button acts on. Each row updates one app (Paper "Update agents
/// from Settings", U1); Codex's two surfaces belong to one agent, so they share its restart rule.
public enum AgentUpdateTarget: String, CaseIterable, Hashable, Sendable {
    case codexCLI
    case codexDesktop
    case claudeCode

    public var appName: String {
        switch self {
        case .codexCLI: "Codex CLI"
        case .codexDesktop: "Codex desktop"
        case .claudeCode: "Claude Code"
        }
    }

    public var agent: AgentSource {
        switch self {
        case .codexCLI, .codexDesktop: .codex
        case .claudeCode: .claude
        }
    }

    /// What detection read for this target once an update ended: its own version and whether that
    /// meets the minimum. Every Claude folder shares one `claude`, so the default folder's reading
    /// (`claude`, nil before any) stands for all.
    public func detected(codex: CodexCapabilities, claude: ClaudeCapabilities?) -> AgentUpdateDetection {
        switch self {
        case .codexCLI: AgentUpdateDetection(version: codex.cliVersion, meetsMinimum: codex.cli)
        case .codexDesktop: AgentUpdateDetection(version: codex.desktopVersion, meetsMinimum: codex.desktop)
        case .claudeCode: AgentUpdateDetection(version: claude?.version, meetsMinimum: claude?.supported ?? false)
        }
    }

    /// The target behind a problem row, or nil for the kinds that never get a button.
    public init?(_ kind: AgentProblem.Kind) {
        switch kind {
        case .codexCLI: self = .codexCLI
        case .codexDesktop: self = .codexDesktop
        case .claudeVersion: self = .claudeCode
        case .status, .newHooks, .usage, .pendingSetup, .usageWriteFailed: return nil
        }
    }
}

/// One target's version as detection read it after an update.
public struct AgentUpdateDetection: Equatable, Sendable {
    public let version: String?
    public let meetsMinimum: Bool

    public init(version: String?, meetsMinimum: Bool) {
        self.version = version
        self.meetsMinimum = meetsMinimum
    }
}

/// An absolute executable and its arguments. The app's PATH lacks Homebrew, so the path is never bare.
public struct AgentUpdateCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// The name a failure uses when the executable cannot be started, such as "brew".
    public var toolName: String { URL(fileURLWithPath: executable).lastPathComponent }
}

/// How the detected Codex CLI was installed. Only a Homebrew cask is updated by Herdly (U3): any
/// other install could be npm, a manual copy, or something else whose updater Herdly cannot know.
public enum CodexCLIInstall: Equatable, Sendable {
    /// `brew` is the absolute path in the cask's own Homebrew prefix.
    case homebrewCask(brew: String)
    case unknown

    /// Classifies the CLI from its path with every symlink already resolved: a cask install lives at
    /// `<prefix>/Caskroom/codex/<version>/…`, and that prefix's `bin/brew` manages it.
    public static func classify(resolvedPath: String?) -> CodexCLIInstall {
        guard let resolvedPath else { return .unknown }
        let components = URL(fileURLWithPath: resolvedPath).standardizedFileURL.pathComponents
        guard let index = components.firstIndex(of: "Caskroom"), index > 1,
              components.count > index + 2, components[index + 1] == "codex" else { return .unknown }
        let prefix = NSString.path(withComponents: Array(components[..<index]))
        return .homebrewCask(brew: (prefix as NSString).appendingPathComponent("bin/brew"))
    }
}

/// The one trailing button a problem row may have.
public enum AgentRowAction: Equatable, Sendable {
    case update(AgentUpdateCommand)
    /// Opens the app at this path so it can update itself; Herdly never updates it (U4).
    case openApp(String)
    case none

    /// The Codex card's action for a problem row: Update for an outdated cask CLI, Open Codex for an
    /// outdated desktop app Herdly selected, and nothing for any other row or a missing surface.
    public static func codex(_ kind: AgentProblem.Kind, _ capabilities: CodexCapabilities) -> AgentRowAction {
        switch kind {
        case .codexCLI:
            guard capabilities.cliInstalled, !capabilities.cli,
                  case .homebrewCask(let brew) = capabilities.cliInstall else { return .none }
            return .update(AgentUpdateCommand(executable: brew, arguments: ["upgrade", "--cask", "codex"]))
        case .codexDesktop:
            guard capabilities.desktopInstalled, !capabilities.desktop,
                  let path = capabilities.desktopPath else { return .none }
            return .openApp(path)
        default:
            return .none
        }
    }

    /// The Claude card's action: `claude update` for an outdated install, since Claude's own updater
    /// routes package-manager installs itself (U2).
    public static func claude(_ kind: AgentProblem.Kind, _ capabilities: ClaudeCapabilities) -> AgentRowAction {
        guard kind == .claudeVersion, capabilities.installed, !capabilities.supported,
              let path = capabilities.executablePath else { return .none }
        return .update(AgentUpdateCommand(executable: path, arguments: ["update"]))
    }
}

/// Where one row's update stands. Nothing here claims success: a finished update returns the row
/// to idle only once detection shows the version meets the minimum, so the row disappears.
public enum AgentUpdateState: Equatable, Sendable {
    case idle
    case updating
    case waitingForApp
    case failed(String)
}

/// How an update command ended, as the runner observed it.
public enum AgentUpdateRunResult: Equatable, Sendable {
    /// The command exited with this status; `output` and `errors` are its bounded stdout and stderr.
    case finished(status: Int32, output: Data, errors: Data)
    /// The command ran past the limit and was stopped.
    case timedOut
    /// The executable could not be started, such as when it is missing.
    case couldNotStart
    /// It started, but Herdly lost track of it (waiting for it failed), so how it ended is unknown.
    case untracked
}

public enum AgentUpdateRequirements {
    /// The longest an update may run before it is stopped and reported as taking too long.
    public static let timeLimit: TimeInterval = 5 * 60
    /// The most of each output stream the runner keeps; reasons come from the end of it.
    public static let maximumOutput = 64 * 1024
}

/// A short, plain reason for a failed update (U7).
public enum AgentUpdateFailure {
    public static let maximumReasonLength = 60

    /// Nil when the command exited successfully. A non-zero exit reads its last error line (stderr
    /// first, then stdout), falling back to the exit status when neither holds readable text.
    public static func reason(_ result: AgentUpdateRunResult, command: AgentUpdateCommand) -> String? {
        switch result {
        case .timedOut: return "took too long"
        case .couldNotStart: return "\(command.toolName) not found"
        case .untracked: return "couldn't track the update"
        case .finished(0, _, _): return nil
        case let .finished(status, output, errors):
            guard let line = meaningfulLine(errors) ?? meaningfulLine(output) else {
                return "\(command.toolName) exited with status \(status)"
            }
            return shortened(line)
        }
    }

    /// The last line naming an error, else the last line holding any letter, with terminal colour
    /// codes and a leading "Error:" removed. Undecodable bytes are replaced, never trusted as text.
    static func meaningfulLine(_ data: Data) -> String? {
        let text = String(decoding: data.suffix(AgentUpdateRequirements.maximumOutput), as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.unicodeScalars.contains { CharacterSet.letters.contains($0) } && !$0.contains("\u{FFFD}") }
        guard let line = lines.last(where: { $0.lowercased().hasPrefix("error") }) ?? lines.last else { return nil }
        let result = line.lowercased().hasPrefix("error:")
            ? String(line.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces) : line
        return result.isEmpty ? nil : result
    }

    static func shortened(_ line: String) -> String {
        guard line.count > maximumReasonLength else { return line }
        let limit = line.prefix(maximumReasonLength - 1)
        let cut = limit.lastIndex(of: " ").map { limit[..<$0] } ?? limit
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// A problem row as drawn: its dot, its text, and its button when it has one.
public struct AgentUpdateRow: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        /// Orange: something to fix.
        case attention
        /// Grey: Herdly or the app is working on it.
        case progress
        /// Red: the last update failed.
        case failure
    }

    public struct Button: Equatable, Sendable {
        public let title: String
        public let accessibilityLabel: String
        public let enabled: Bool

        public init(title: String, accessibilityLabel: String, enabled: Bool) {
            self.title = title
            self.accessibilityLabel = accessibilityLabel
            self.enabled = enabled
        }
    }

    public let tone: Tone
    public let text: String
    public let button: Button?

    public init(tone: Tone, text: String, button: Button?) {
        self.tone = tone
        self.text = text
        self.button = button
    }
}

/// Every row's update state, plus each agent's "Restart required" after a successful update.
/// Time is passed in, so the restart rule and its clearing are deterministic. Restart required is
/// held only in memory: after Herdly relaunches, the header returns to its detected status.
public struct AgentUpdates: Equatable, Sendable {
    private var states: [AgentUpdateTarget: AgentUpdateState] = [:]
    /// When each agent's latest update succeeded; a later SessionStart from that agent clears it.
    private var restartSince: [AgentSource: Double] = [:]
    /// The versions updated since that agent's last restart, for one combined footnote.
    private var updatedVersions: [AgentUpdateTarget: String] = [:]

    public static let installNote = "Herdly can't tell how Codex CLI was installed, so it can't update it for you. Update it the way you installed it, then choose Review Again from the ⋯ menu."

    public init() {}

    /// The Codex card's note while it shows a Codex CLI version row with no Update button (artboard 05).
    public static func codexInstallNote(_ summary: AgentSummary, _ capabilities: CodexCapabilities) -> String? {
        guard summary.problems.contains(where: { $0.kind == .codexCLI }), capabilities.cliInstalled,
              AgentRowAction.codex(.codexCLI, capabilities) == .none else { return nil }
        return installNote
    }

    public func state(_ target: AgentUpdateTarget) -> AgentUpdateState { states[target] ?? .idle }

    /// Starts one row's update. False, changing nothing, while that row is already updating (U5).
    public mutating func begin(_ target: AgentUpdateTarget) -> Bool {
        guard state(target) != .updating else { return false }
        states[target] = .updating
        return true
    }

    /// The app was asked to open so it can update itself.
    public mutating func openedApp(_ target: AgentUpdateTarget) {
        guard state(target) != .updating else { return }
        states[target] = .waitingForApp
    }

    /// Opening the app failed.
    public mutating func openFailed(_ target: AgentUpdateTarget, reason: String) {
        states[target] = .failed(AgentUpdateFailure.shortened(reason))
    }

    /// The update command ended and detection has rerun. Succeeds only when the command exited
    /// cleanly and the detected version now meets the minimum; returns the card's footnote then.
    /// A result for a row that is not updating is late and ignored.
    @discardableResult
    public mutating func finish(_ target: AgentUpdateTarget, command: AgentUpdateCommand, result: AgentUpdateRunResult,
                                detection: AgentUpdateDetection, now: Double) -> String? {
        guard state(target) == .updating else { return nil }
        if let reason = AgentUpdateFailure.reason(result, command: command) {
            states[target] = .failed(reason)
            return nil
        }
        let version = detection.version
        guard detection.meetsMinimum, let version else {
            states[target] = .failed(version.map { "still \($0) afterwards" } ?? "couldn't read the new version")
            return nil
        }
        return succeed(target, version: version, now: now)
    }

    /// A setup detection landed. A row waiting for its app to update itself stops waiting once the
    /// app meets the minimum, and that counts as the app's update; other rows are untouched.
    @discardableResult
    public mutating func detected(_ target: AgentUpdateTarget, version: String?, meetsMinimum: Bool,
                                  now: Double) -> String? {
        guard state(target) == .waitingForApp, meetsMinimum, let version else { return nil }
        return succeed(target, version: version, now: now)
    }

    /// A SessionStart from `agent` captured at `at`. Only one at or after that agent's update clears
    /// its Restart required; the other agent's sessions never do.
    public mutating func sessionStarted(_ agent: AgentSource, at: Double) {
        guard let since = restartSince[agent], at >= since else { return }
        restartSince[agent] = nil
        for target in AgentUpdateTarget.allCases where target.agent == agent { updatedVersions[target] = nil }
    }

    public func restartRequired(_ agent: AgentSource) -> Bool { restartSince[agent] != nil }

    /// When the newest Codex SessionStart was received, from either surface's hook events; nil when
    /// none has a readable time.
    public static func latestCodexSessionStart(cliEvents: [CLIEvent], desktopEvents: [DesktopEvent]) -> Double? {
        var times: [String] = []
        for case let .sessionStarted(_, receivedAt) in cliEvents { times.append(receivedAt) }
        for case let .sessionStarted(_, receivedAt) in desktopEvents { times.append(receivedAt) }
        return times.compactMap(RolloutTimestamp.parse).filter(\.isFinite).max()
    }

    /// The header beside the agent's name: "Restart required" after an update until a new session
    /// starts, otherwise the detected status. Checking stays Checking.
    public func header(_ status: AgentHeaderStatus, for agent: AgentSource) -> AgentHeaderStatus {
        guard restartRequired(agent), status != .checking else { return status }
        return .attention("Restart required")
    }

    /// An agent card's summary as shown: the detected one, with the header reading Restart required
    /// while that agent needs one. Both cards build their header here.
    public func summary(_ summary: AgentSummary, for agent: AgentSource) -> AgentSummary {
        AgentSummary(subtitle: summary.subtitle, status: header(summary.status, for: agent), problems: summary.problems)
    }

    /// How a version problem row with `value` and `action` reads in its current state.
    public func row(_ target: AgentUpdateTarget, value: String, action: AgentRowAction) -> AgentUpdateRow {
        let title: String, label: String
        switch action {
        case .none: return AgentUpdateRow(tone: .attention, text: value, button: nil)
        case .update: (title, label) = ("Update", "Update \(target.appName)")
        case .openApp: (title, label) = ("Open Codex", "Open Codex")
        }
        switch state(target) {
        case .idle:
            return AgentUpdateRow(tone: .attention, text: value,
                                  button: .init(title: title, accessibilityLabel: label, enabled: true))
        case .updating:
            return AgentUpdateRow(tone: .progress, text: "Updating…",
                                  button: .init(title: title, accessibilityLabel: label, enabled: false))
        case .waitingForApp:
            return AgentUpdateRow(tone: .progress, text: "Waiting for Codex to update itself",
                                  button: .init(title: title, accessibilityLabel: label, enabled: true))
        case .failed(let reason):
            return AgentUpdateRow(tone: .failure, text: "Couldn't update: \(reason)",
                                  button: .init(title: "Try Again", accessibilityLabel: "\(label) again", enabled: true))
        }
    }

    private mutating func succeed(_ target: AgentUpdateTarget, version: String, now: Double) -> String {
        states[target] = .idle
        restartSince[target.agent] = now
        updatedVersions[target] = version
        let updated = AgentUpdateTarget.allCases
            .filter { $0.agent == target.agent }
            .compactMap { candidate in updatedVersions[candidate].map { "\(candidate.appName) to \($0)" } }
        return "Updated \(updated.joined(separator: " and ")). Sessions already open keep the old version until you restart them."
    }
}
