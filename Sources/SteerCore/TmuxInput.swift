import Foundation

// tmux typed input (ADR 0017), the gated question-digit relay, ADR 0016's visible test for a pane and
// the Settings card (product.md, "Agreed terminal host presentation"). Pure; SteerApp runs `send-keys`
// with a bounded wait and owns the rollout and inventory reads.

// MARK: - Typed input

public enum TmuxInput {
    /// One write as `send-keys` arguments: text literally (`-l`, after `--` so text starting with `-`
    /// stays text), Claude's text and CR in one call, and Codex's submit as a separate `Enter`
    /// (tmux-live.md, "send-keys to a TUI").
    public static func arguments(_ write: TypedWrite, into pane: TypedInputPane) -> [String] {
        switch write {
        case .text(let text): ["send-keys", "-t", pane.paneID, "-l", "--", literal(text)]
        case .textAndSubmit(let text): ["send-keys", "-t", pane.paneID, "-l", "--", literal(text + "\r")]
        case .submit: ["send-keys", "-t", pane.paneID, "Enter"]
        }
    }

    /// One `send-keys -l` argument that tmux types exactly as `text`. tmux's command parser takes an
    /// argument ending in an unescaped `;` as the end of the command and drops that `;`, even after
    /// `-l --` (an isolated tmux 3.8: `abc;` typed `abc`, and `;` alone typed nothing yet exited 0); a
    /// trailing `\;` types `;`. So a trailing `;` gets one backslash before it, and only that one: `a\;`
    /// becomes `a\\;`, which types `a\;`. Nothing else in an argument is special.
    public static func literal(_ text: String) -> String {
        guard text.hasSuffix(";") else { return text }
        return String(text.dropLast()) + "\\;"
    }

    /// A call that did not return in time counts as sent (ADR 0017, "Multiplexers"). A non-zero exit is
    /// tmux refusing before it wrote (an unknown pane exits 1 with "can't find pane").
    public static func delivery(_ outcome: TmuxCommandOutcome) -> TypedInputDelivery {
        switch outcome {
        case .succeeded: .written
        case .failed, .notLaunched: .notWritten
        case .timedOut: .possiblyWritten
        }
    }

    /// The reply route for a fresh binding and the tmux read behind it: a tmux pane needs ADR 0014's pane
    /// layer and `pane_in_mode` 0 (`TmuxLayout.inputLayer`), otherwise it is unreachable; a tab bound in
    /// another host keeps that host's route.
    public static func route(_ binding: TerminalTabBinding, snapshot: TmuxSnapshot?) -> TerminalReplyRoute? {
        guard case .bound(let target) = binding, target.host == .tmux else { return TerminalReplyRoute.from(binding) }
        guard let snapshot, TmuxLayout.inputLayer(target.tabID, in: snapshot) == nil else { return .unreachable }
        return TerminalReplyRoute.from(binding)
    }
}

// MARK: - Question digits

extension TmuxInput {
    /// Whether tmux may carry a Codex question's digit (ADR 0017, "Live proof per host"). The relay is
    /// built through the shared `TerminalQuestionKeys` route and tested, but no tmux key is offered while
    /// this is false: a tmux question card says "Answer this in Codex." tmux's acceptance (#246) flips it
    /// once a live run shows the digit alone selects and submits a Codex option in a tmux pane.
    public static let questionDigitsProvenLive = false

    /// One digit, typed literally, never followed by Enter.
    public static func digitArguments(_ key: String, into pane: TypedInputPane) -> [String] {
        ["send-keys", "-t", pane.paneID, "-l", "--", literal(key)]
    }
}

// MARK: - Visits

public enum TmuxVisibility {
    /// ADR 0016's test for a tmux pane: the frontmost host's visible tab (`hostFront`, by its tty, read
    /// with macOS's frontmost app) runs the client of a session whose current pane is returned, and that
    /// pane passes the layout and client checks. Whether it is a session's bound pane is the caller's
    /// comparison. A tmux read or host read that failed is unknown.
    public static func reading(_ snapshot: TmuxSnapshot?,
                               hostFront: TerminalVisibilityReading<String>) -> TerminalVisibilityReading<String> {
        guard let snapshot else { return .unknown }
        switch hostFront {
        case .unknown: return .unknown
        case .nothing, .unchecked: return .nothing
        case .visible(let tty):
            let clients = snapshot.clients.filter { !$0.controlMode && $0.tty == tty }
            guard clients.count == 1, let client = clients.first,
                  TmuxLayout.paneLayer(client.paneID, in: snapshot) == nil,
                  TmuxLayout.client(for: client.paneID, in: snapshot) == .success(client) else { return .nothing }
            return .visible(client.paneID)
        }
    }
}

// MARK: - Settings card

/// A live process holding a session, as the non-default socket line reads it: its tty and the
/// executable names of its ancestry, from itself up.
public struct TmuxSessionProcess: Equatable, Sendable {
    public let tty: String?
    public let ancestorCommands: [String]

    public init(tty: String?, ancestorCommands: [String]) {
        self.tty = tty
        self.ancestorCommands = ancestorCommands
    }
}

public struct TmuxSettingsRow: Equatable, Sendable {
    public let badge: TerminalAppSettingsRow.Badge
    public let detail: String
    /// One line per problem, each a separate fix.
    public let problems: [String]
}

/// The tmux card in Settings › Terminals. Hidden until acceptance (#246): `TerminalHost.showsCard`
/// stays false.
public enum TmuxPresentation {
    public static let noTerminalLine = "Turn on the terminal you run tmux in."
    /// The not-found pattern WezTerm's card uses, naming tmux's fixed locations.
    public static let notFoundLine = "Steer can't find tmux in /opt/homebrew/bin, /usr/local/bin or /usr/bin."
    /// The ownership failure: the default socket or its server is not this user's.
    public static let untrustedSocketLine = "Steer can't read tmux's default socket. Check that it runs as you."
    /// Any other failed read: the shared agreed line.
    public static let unreadableLine = OpenUnavailableReason.hostUnreadable(.tmux).cardLine
    /// product.md, "Problem lines": "sessions seen on a socket other than the default can't be reached."
    public static let otherSocketLine = "Sessions seen on a socket other than the default can't be reached."
    public static let footer =
        "Steer returns to a pane alone in its window, with one client, on tmux's default socket; otherwise Open raises the terminal running tmux. Replies are typed into the exact pane."

    /// - Parameters:
    ///   - read: the latest read of the default server, nil before one (or while tmux is not contacted).
    ///   - sessionsSeen: a scan has bound a session to a tmux pane.
    ///   - otherSocketSeen: `otherSocketSeen(_:defaultPaneTTYs:)` held at the latest scan.
    public static func settingsRow(on: Bool, anyTerminalOn: Bool, read: TmuxRead?, sessionsSeen: Bool,
                                   otherSocketSeen: Bool) -> TmuxSettingsRow {
        guard on else {
            return TmuxSettingsRow(badge: .off, detail: "Steer never scans or contacts tmux.", problems: [])
        }
        var problems: [String] = []
        if !anyTerminalOn { problems.append(noTerminalLine) }
        switch read {
        case .binaryNotFound?: problems.append(notFoundLine)
        case .untrustedSocket?: problems.append(untrustedSocketLine)
        case .unreadable?: problems.append(unreadableLine)
        case .notRunning?, .snapshot?, nil: break
        }
        if otherSocketSeen { problems.append(otherSocketLine) }
        guard problems.isEmpty else {
            return TmuxSettingsRow(badge: .needsAttention, detail: "Fix each item below.", problems: problems)
        }
        return TmuxSettingsRow(badge: sessionsSeen ? .ready : .notInUse,
                               detail: sessionsSeen ? "tmux's default server is readable." : "No tmux sessions seen.",
                               problems: [])
    }

    /// Whether a live session runs under a tmux server other than the default one: its process descends
    /// from a `tmux` process, yet no pane of the default server has its tty. nil `defaultPaneTTYs` (the
    /// default server unread or unreadable) says nothing; its own line covers it. For the card only:
    /// it never binds or vetoes.
    public static func otherSocketSeen(_ processes: [TmuxSessionProcess], defaultPaneTTYs: Set<String>?) -> Bool {
        guard let defaultPaneTTYs else { return false }
        return processes.contains { process in
            guard process.ancestorCommands.dropFirst().contains("tmux"),
                  let tty = process.tty.flatMap(GhosttyTTYMatch.normalizedTTY) else { return false }
            return !defaultPaneTTYs.contains(tty)
        }
    }
}
