import Foundation

// Zellij typed input (ADR 0017), the gated question-digit relay and the Settings card (product.md,
// "Agreed terminal host presentation"). Pure; SteerApp runs `write-chars` and `write` with a bounded
// wait and owns the rollout and inventory reads.

// MARK: - Typed input

public enum ZellijInput {
    /// One write as Zellij arguments: text with `write-chars --pane-id` (after `--`, so text starting with
    /// `-` stays text; an isolated Zellij 0.45.1 typed `-dash; echo semi;` exactly), Claude's text and CR
    /// in one call, and Codex's submit as a separate `write 13` (zellij-live.md, "TUI prompt"). nil for a
    /// pane that is not a Zellij pane handle.
    public static func arguments(_ write: TypedWrite, into pane: TypedInputPane) -> [String]? {
        guard pane.host == .zellij, let target = ZellijPaneTarget(handle: pane.paneID) else { return nil }
        let prefix = ["--session", target.session, "action"]
        switch write {
        case .text(let text): return prefix + ["write-chars", "--pane-id", target.paneArgument, "--", text]
        case .textAndSubmit(let text): return prefix + ["write-chars", "--pane-id", target.paneArgument, "--", text + "\r"]
        case .submit: return prefix + ["write", "--pane-id", target.paneArgument, "13"]
        }
    }

    /// Immediately before every write: `write-chars --pane-id` to an unknown pane exits 0 and writes
    /// nothing (zellij-live.md), so its exit status cannot show the target existed. The write goes only
    /// when a read taken just now shows the bound pane still a live, single terminal pane of its session
    /// under the server the fresh check read (a restarted server reuses pane ids).
    public static func writeAllowed(_ target: ZellijPaneTarget, expected: ZellijServerIdentity?,
                                    current: ZellijSnapshot?) -> Bool {
        guard let expected, let current, current.server(target.session) == expected else { return false }
        return ZellijLayout.paneLayer(target, in: current) == nil
    }

    /// A call that did not return in time counts as sent (ADR 0017, "Multiplexers"). A non-zero exit is
    /// Zellij refusing before it wrote (no such session).
    public static func delivery(_ outcome: ZellijCommandOutcome) -> TypedInputDelivery {
        switch outcome {
        case .succeeded: .written
        case .failed, .notLaunched: .notWritten
        case .timedOut: .possiblyWritten
        }
    }

    /// The reply route for a session's Zellij binding: a bound pane needs ADR 0014's pane layer, otherwise
    /// it is unreachable; a session Zellij has nothing to say about keeps the other hosts' route (nil).
    public static func route(_ binding: ZellijBinding, snapshot: ZellijSnapshot?) -> TerminalReplyRoute? {
        switch binding {
        case .notInZellij: return nil
        case .unavailable: return .unreachable
        case .bound(let target):
            guard let snapshot, ZellijLayout.paneLayer(target, in: snapshot) == nil else { return .unreachable }
            return .pane(TypedInputPane(host: .zellij, paneID: target.handle, tty: nil))
        }
    }
}

// MARK: - Question digits

extension ZellijInput {
    /// Whether Zellij may carry a Codex question's digit (ADR 0017, "Live proof per host"). The relay is
    /// built through the shared `TerminalQuestionKeys` route and tested, but no Zellij key is offered while
    /// this is false: a Zellij question card says "Answer this in Codex." Zellij's acceptance (#247) flips
    /// it once a live run shows the digit alone selects and submits a Codex option in a Zellij pane.
    public static let questionDigitsProvenLive = false

    /// One digit with `write-chars`, never followed by a carriage return. nil for a pane that is not a
    /// Zellij pane handle.
    public static func digitArguments(_ key: String, into pane: TypedInputPane) -> [String]? {
        arguments(.text(key), into: pane)
    }
}

// MARK: - Settings card

public struct ZellijSettingsRow: Equatable, Sendable {
    public let badge: TerminalAppSettingsRow.Badge
    public let detail: String
    /// One line per problem, each a separate fix.
    public let problems: [String]
}

/// The Zellij card in Settings › Terminals. Hidden until acceptance (#247): `TerminalHost.showsCard`
/// stays false.
public enum ZellijPresentation {
    public static let noTerminalLine = "Turn on the terminal you run Zellij in."
    /// product.md, "Problem lines": "Zellij: older than 0.44.1".
    public static let versionLine = "Zellij is older than 0.44.1."
    /// product.md, "Problem lines": "Zellij: … more than one `zellij` client process running".
    public static let secondClientLine = "More than one zellij client process is running."
    /// The not-found pattern WezTerm's and tmux's cards use, naming Zellij's fixed locations.
    public static let notFoundLine = "Steer can't find Zellij in /opt/homebrew/bin or /usr/local/bin."
    /// An untrusted socket directory and any other failed read: the shared agreed line.
    public static let unreadableLine = OpenUnavailableReason.hostUnreadable(.zellij).cardLine
    public static let footer =
        "Steer returns to a pane alone in its tab, with one Zellij client, in Zellij's default socket directory; otherwise Open raises the terminal running Zellij. Replies are typed into the exact pane."

    /// - Parameters:
    ///   - read: the latest read of the default socket directory, nil before one (or while Zellij is not contacted).
    ///   - sessionsSeen: a scan has bound a session to a Zellij pane.
    public static func settingsRow(on: Bool, anyTerminalOn: Bool, read: ZellijRead?, sessionsSeen: Bool) -> ZellijSettingsRow {
        guard on else {
            return ZellijSettingsRow(badge: .off, detail: "Steer never scans or contacts Zellij.", problems: [])
        }
        var problems: [String] = []
        if !anyTerminalOn { problems.append(noTerminalLine) }
        switch read {
        case .binaryNotFound?: problems.append(notFoundLine)
        case .unsupportedVersion?: problems.append(versionLine)
        case .untrustedSocket?, .unreadable?: problems.append(unreadableLine)
        case .snapshot(let snapshot)?:
            if snapshot.processes.clientProcesses.count > 1 { problems.append(secondClientLine) }
        case .notRunning?, nil: break
        }
        guard problems.isEmpty else {
            return ZellijSettingsRow(badge: .needsAttention, detail: "Fix each item below.", problems: problems)
        }
        return ZellijSettingsRow(badge: sessionsSeen ? .ready : .notInUse,
                                 detail: sessionsSeen ? "Zellij's default socket directory is readable." : "No Zellij sessions seen.",
                                 problems: [])
    }
}
