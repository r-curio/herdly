import Foundation
import Testing
@testable import HerdlyCore

// ADR 0013: CLI sessions bind to terminal tabs by tty across the enabled hosts. Fixtures follow the
// saved host output of the live proofs (docs/evidence/iterm2-live.md, terminal-app-live.md,
// wezterm-live.md): `ps -o pid=,stat=,comm= -t <tty>` rows and each host's tab tty and title.

// `ps -o pid=,stat=,comm= -t ttys012` for a tab running Codex.
private let codexPS = """
  812 Ss     login
  814 S      -zsh
60859 S+     codex

"""

@Test func foregroundProcessesComeFromThePlusStateOfPsRows() {
    let processes = TerminalForegroundProcesses.parse(codexPS)
    #expect(processes == [
        TerminalProcess(pid: 812, name: "login", foreground: false),
        TerminalProcess(pid: 814, name: "-zsh", foreground: false),
        TerminalProcess(pid: 60859, name: "codex", foreground: true),
    ])
}

// MARK: - Hook-recorded identifiers

// What an iTerm2 tab launched from another agent's session inherits (iTerm2 proof), plus WezTerm's
// and Zellij's own values.
private let hookEnvironment = [
    "ITERM_SESSION_ID": "w0t2p0:9C1F6E2A-6B7D-4E0F-A1B2-C3D4E5F60718",
    "TERM_SESSION_ID": "w0t2p0:9C1F6E2A-6B7D-4E0F-A1B2-C3D4E5F60718",
    "WEZTERM_PANE": "4",
    "ZELLIJ_PANE_ID": "2",
    "ZELLIJ_SESSION_NAME": "fearless-sloth",
]

private func hookRecord(source: String, environment: [String: String] = hookEnvironment) -> [String: Any] {
    var record: [String: Any] = ["hook_event_name": "SessionStart", "session_id": claudeSession, "source": source]
    TerminalHookIdentifiers.record(from: environment, into: &record)
    return record
}

@Test func hookRecordsKeepTerminalIdentifiersForDiagnostics() {
    let record = hookRecord(source: ClaudeSetupRequirements.helperSource)
    #expect(TerminalHookIdentifiers.diagnostics(in: record) == [
        "iterm_session_id": "w0t2p0:9C1F6E2A-6B7D-4E0F-A1B2-C3D4E5F60718",
        "term_session_id": "w0t2p0:9C1F6E2A-6B7D-4E0F-A1B2-C3D4E5F60718",
        "wezterm_pane": "4",
        "zellij_pane_id": "2",
        "zellij_session_name": "fearless-sloth",
    ])
    // A malformed or oversized value is absent, never repaired.
    let malformed = hookRecord(source: ClaudeSetupRequirements.helperSource,
                               environment: ["WEZTERM_PANE": "4\n", "ITERM_SESSION_ID": String(repeating: "a", count: 200)])
    #expect(TerminalHookIdentifiers.diagnostics(in: malformed) == [:])
}

@Test func hookIdentifiersNeverDecideABindingOutsideZellij() {
    // iTerm2, Terminal.app and WezTerm identifiers alone give the binding nothing.
    var outsideZellij = hookEnvironment
    outsideZellij["ZELLIJ_PANE_ID"] = nil
    outsideZellij["ZELLIJ_SESSION_NAME"] = nil
    #expect(TerminalHookIdentifiers.zellijPane(in: hookRecord(source: ClaudeSetupRequirements.helperSource,
                                                              environment: outsideZellij)) == nil)
    // Zellij's pane and session are a Claude Code binding input (ADR 0014)...
    #expect(TerminalHookIdentifiers.zellijPane(in: hookRecord(source: ClaudeSetupRequirements.helperSource))
        == ZellijHookPane(paneID: "2", sessionName: "fearless-sloth"))
    // ...but never from a Codex record, whose daemon inherited another pane's environment.
    #expect(TerminalHookIdentifiers.zellijPane(in: hookRecord(source: CodexSetupRequirements.helperSource)) == nil)
    // A pane without its session cannot be placed.
    #expect(TerminalHookIdentifiers.zellijPane(in: hookRecord(source: ClaudeSetupRequirements.helperSource,
                                                              environment: ["ZELLIJ_PANE_ID": "2"])) == nil)
    // The tab rules take no hook identifier at all: Claude follows its process even when the
    // recorded iTerm2 session names another tab.
    #expect(claude(switches: switches([.iTerm2]),
                   inventories: [.iTerm2: .tabs([claudeTab("w0t2p0:9C1F6E2A-6B7D-4E0F-A1B2-C3D4E5F60718",
                                                           tty: "/dev/ttys031"),
                                                 claudeTab("w0t0p0:0D0E0F10-1112-4314-9516-171819202122")])])
        == .bound(TerminalTabTarget(host: .iTerm2, tabID: "w0t0p0:0D0E0F10-1112-4314-9516-171819202122",
                                    tty: claudeTTY)))
}

// MARK: - Codex CLI

private let codexSession = "019a7c1e-5b2d-7f30-9c11-2f4e8a6b0001"
private let codexTitle = "019a7c1e-5b2d-7f30-9c11-2f4e8..."
private let otherCodex = "9f3c2b10-1111-4222-8333-444455556666"
private let realTTY = "/dev/ttys012"

// `ps` for a decoy tab that printed Codex's title and then ran `sleep`.
private let sleepPS = """
  901 Ss     login
  903 S+     sleep
"""

private func tab(_ id: String, tty: String? = realTTY, title: String? = codexTitle, panes: Int = 1) -> TerminalTab {
    TerminalTab(tabID: id, tty: tty, title: title, paneCount: panes)
}

private func switches(_ hosts: Set<TerminalHost> = [.iTerm2]) -> TerminalHostSwitches {
    TerminalHostSwitches(enabled: hosts)
}

private func codex(_ sessionID: String = codexSession, liveness: HerdrSessionLiveness = .live,
                   live: Set<String> = [codexSession, otherCodex],
                   switches hostSwitches: TerminalHostSwitches = switches(),
                   inventories: [TerminalHost: TerminalHostInventory] = [.iTerm2: .tabs([tab("A1")])],
                   processes: [String: [TerminalProcess]] = [realTTY: TerminalForegroundProcesses.parse(codexPS)!],
                   secondRead: [TerminalHost: TerminalHostInventory]? = nil) -> TerminalTabBinding {
    TerminalTabBindingRules.codex(sessionID: sessionID, liveness: liveness, liveSessions: live,
                                  switches: hostSwitches, inventories: inventories, processes: processes,
                                  secondRead: secondRead ?? inventories)
}

@Test func codexBindsToTheOneTabShowingItsTitleWithOneForegroundCodex() {
    #expect(codex() == .bound(TerminalTabTarget(host: .iTerm2, tabID: "A1", tty: realTTY)))
}

@Test func aDecoyCarryingCodexsTitleNeverBinds() {
    let decoyTTY = "/dev/ttys013"
    let decoy = tab("A3", tty: decoyTTY)
    let decoyPS = [decoyTTY: TerminalForegroundProcesses.parse(sleepPS)!]
    // The real tab is gone: a decoy without a foreground `codex` is no candidate, so nothing carries the title.
    #expect(codex(inventories: [.iTerm2: .tabs([decoy])], processes: decoyPS) == .unavailable(.titleNotFound))
}

// #268 (user decision 2026-10-13): a titled tab whose `ps -t` shows no foreground `codex` neither binds
// nor blocks the real tab, on every host whose tabs list a tty.
@Test func aDecoyBesideTheRealTabLeavesTheRealTabBoundOnEveryTTYHost() {
    let decoyTTY = "/dev/ttys013"
    let processes = [realTTY: TerminalForegroundProcesses.parse(codexPS)!,
                     decoyTTY: TerminalForegroundProcesses.parse(sleepPS)!]
    for host in [TerminalHost.iTerm2, .terminalApp, .wezTerm, .ghostty, .tmux] {
        // tmux is contacted only beside a terminal host (ADR 0014), here an iTerm2 that is not running.
        var inventories: [TerminalHost: TerminalHostInventory] = [.iTerm2: .notRunning]
        inventories[host] = .tabs([tab("decoy", tty: decoyTTY), tab("real")])
        #expect(codex(switches: switches([host, .iTerm2]), inventories: inventories, processes: processes)
            == .bound(TerminalTabTarget(host: host, tabID: "real", tty: realTTY)), "\(host)")
    }
    // The decoy may be in another enabled host than the real tab.
    let across: [TerminalHost: TerminalHostInventory] = [
        .terminalApp: .tabs([tab("window 9882", tty: decoyTTY)]),
        .iTerm2: .tabs([tab("A1")]),
    ]
    #expect(codex(switches: switches([.iTerm2, .terminalApp]), inventories: across, processes: processes)
        == .bound(TerminalTabTarget(host: .iTerm2, tabID: "A1", tty: realTTY)))
    // The second read ignores the decoy the same way.
    #expect(codex(switches: switches([.iTerm2, .terminalApp]), inventories: across, processes: processes,
                  secondRead: across) == .bound(TerminalTabTarget(host: .iTerm2, tabID: "A1", tty: realTTY)))
}

@Test func twoTitledTabsThatBothRunCodexStayUnbound() {
    let secondTTY = "/dev/ttys014"
    let processes = [realTTY: TerminalForegroundProcesses.parse(codexPS)!,
                     secondTTY: TerminalForegroundProcesses.parse(codexPS)!]
    #expect(codex(inventories: [.iTerm2: .tabs([tab("A1"), tab("A2", tty: secondTTY)])], processes: processes)
        == .unavailable(.duplicateTitles(2)))
}

@Test func aTitledTabWhoseProcessesCannotBeReadIsNeverTakenForADecoy() {
    // `ps` failed for the second titled tab: it may run `codex`, so it still counts and nothing binds.
    #expect(codex(inventories: [.iTerm2: .tabs([tab("A1"), tab("A2", tty: "/dev/ttys014")])])
        == .unavailable(.duplicateTitles(2)))
    // A titled tab first seen by the second read has no `ps` read at all: the binding is void.
    #expect(codex(secondRead: [.iTerm2: .tabs([tab("A1"), tab("A2", tty: "/dev/ttys014")])])
        == .unavailable(.titleChanged))
}

@Test func aSplitTitledTabStillCountsWithoutAForegroundCodex() {
    // `ps -t` reads one pane's tty; another pane of the split may run the session, so it is no decoy.
    let decoyTTY = "/dev/ttys013"
    let processes = [realTTY: TerminalForegroundProcesses.parse(codexPS)!,
                     decoyTTY: TerminalForegroundProcesses.parse(sleepPS)!]
    #expect(codex(inventories: [.iTerm2: .tabs([tab("A1"), tab("A3", tty: decoyTTY, panes: 2)])], processes: processes)
        == .unavailable(.duplicateTitles(2)))
}

@Test func twoForegroundCodexProcessesOnOneTTYNeverBind() {
    let twoCodex = """
      812 Ss     login
    60859 S+     codex
    60990 S+     /opt/homebrew/bin/codex
    """
    #expect(codex(processes: [realTTY: TerminalForegroundProcesses.parse(twoCodex)!])
        == .unavailable(.foregroundProcesses(count: 2)))
}

@Test func aTitleInTabsOfTwoEnabledHostsNeverBinds() {
    // Terminal.app shows the same title in its `custom title`, on another tty.
    let inventories: [TerminalHost: TerminalHostInventory] = [
        .iTerm2: .tabs([tab("A1")]),
        .terminalApp: .tabs([tab("window 9882", tty: "/dev/ttys005")]),
    ]
    #expect(codex(switches: switches([.iTerm2, .terminalApp]), inventories: inventories)
        == .unavailable(.duplicateTitles(2)))
}

@Test func anUnreadableHostDoesNotStopACodexSessionAReadableHostHolds() {
    let both = switches([.iTerm2, .wezTerm])
    let bound = TerminalTabBinding.bound(TerminalTabTarget(host: .iTerm2, tabID: "A1", tty: realTTY))
    // ADR 0013, 2026-11-25: WezTerm's `cli list` failed, but iTerm2's titled tab runs the one foreground
    // `codex`, so it binds.
    #expect(codex(switches: both, inventories: [.iTerm2: .tabs([tab("A1")]), .wezTerm: .unreadable]) == bound)
    #expect(codex(switches: both, inventories: [.iTerm2: .tabs([tab("A1")])]) == bound)
    // No readable host shows the title: the unreadable host may hold it.
    #expect(codex(switches: both, inventories: [.iTerm2: .tabs([]), .wezTerm: .unreadable])
        == .unavailable(.hostUnreadable(.wezTerm)))
    // Two readable titled tabs that both run `codex` still leave it unbound.
    #expect(codex(switches: both, inventories: [.iTerm2: .tabs([tab("A1"), tab("A2")]), .wezTerm: .unreadable])
        == .unavailable(.duplicateTitles(2)))
    // A host that is not running holds nothing.
    #expect(codex(switches: both, inventories: [.iTerm2: .tabs([tab("A1")]), .wezTerm: .notRunning])
        == .bound(TerminalTabTarget(host: .iTerm2, tabID: "A1", tty: realTTY)))
}

@Test func aSwitchedOffHostNeitherHoldsNorBlocksABinding() {
    let inventories: [TerminalHost: TerminalHostInventory] = [
        .iTerm2: .tabs([tab("A1")]),
        .wezTerm: .tabs([tab("7", tty: "/dev/ttys020")]),
        .terminalApp: .unreadable,
    ]
    #expect(codex(switches: switches([.iTerm2]), inventories: inventories)
        == .bound(TerminalTabTarget(host: .iTerm2, tabID: "A1", tty: realTTY)))
}

@Test func aSecondReadMustStillShowTheSameTabWithTheSameTitle() {
    // The user renamed the tab between the inventory and the `ps` read.
    #expect(codex(secondRead: [.iTerm2: .tabs([tab("A1", title: "renamed")])]) == .unavailable(.titleChanged))
    // The tab closed and its tty went to a new tab showing the same title.
    #expect(codex(secondRead: [.iTerm2: .tabs([tab("A9")])]) == .unavailable(.titleChanged))
    #expect(codex(secondRead: [.iTerm2: .unreadable]) == .unavailable(.hostUnreadable(.iTerm2)))
}

@Test func codexNeedsAUniqueShortenedIdentifierAndALiveSession() {
    let sibling = "019a7c1e-5b2d-7f30-9c11-2f4e8a6b0002"   // same 29-character prefix
    #expect(codex(live: [codexSession, sibling]) == .unavailable(.sessionPrefixNotUnique(2)))
    #expect(codex(liveness: .ended) == .unavailable(.sessionEnded))
    // A session missing from the live list never takes the tab of a live sibling sharing its prefix.
    #expect(codex(live: [sibling, otherCodex]) == .unavailable(.sessionNotLive))
    #expect(codex("not-a-uuid") == .unavailable(.titleNotFound))
    // Codex session IDs are compared lowercased.
    #expect(codex(codexSession.uppercased())
        == .bound(TerminalTabTarget(host: .iTerm2, tabID: "A1", tty: realTTY)))
}

@Test func aTitleOnAHostWithoutTTYNeverBindsByTheseRules() {
    // Ghostty without `tty` lists the title; ADR 0005's title rule decides that tab, not these.
    #expect(codex(switches: switches([.ghostty]), inventories: [.ghostty: .tabs([tab("g1", tty: nil)])])
        == .unavailable(.ttyUnknown(.ghostty)))
    // It still counts for uniqueness against a tab in another host.
    #expect(codex(switches: switches([.ghostty, .iTerm2]),
                  inventories: [.ghostty: .tabs([tab("g1", tty: nil)]), .iTerm2: .tabs([tab("A1")])])
        == .unavailable(.duplicateTitles(2)))
}

@Test func anUnreadableProcessListNeverBinds() {
    #expect(codex(processes: [:]) == .unavailable(.processesUnreadable))
    #expect(TerminalForegroundProcesses.parse("  812 Ss\n") == nil)
    #expect(TerminalForegroundProcesses.parse("pid Ss login\n") == nil)
}

@Test func aSplitTabNeverBinds() {
    #expect(codex(inventories: [.iTerm2: .tabs([tab("A1", panes: 2)])]) == .unavailable(.split))
}

// MARK: - Claude Code

private let claudeSession = "12e2faa8-6707-4877-97e2-ab6ee14acaaa"
private let claudeTTY = "/dev/ttys005"
private let claudePID: Int32 = 70412
private let claudeStart = "Mon Oct 12 08:01:09 2026"

// `ps -o pid=,stat=,comm= -t ttys005` for a Terminal.app tab running Claude's version-named binary.
private let claudePS = """
70410 Ss     login
70412 S+     /Users/test/.local/share/claude/versions/2.1.296
70533 S+     caffeinate
"""

private func claudeTab(_ id: String = "window 9882", tty: String = claudeTTY,
                       title: String? = "Herdly Claude \(claudeSession)", panes: Int = 1) -> TerminalTab {
    TerminalTab(tabID: id, tty: tty, title: title, paneCount: panes)
}

private func claude(liveness: HerdrSessionLiveness = .live,
                    process: TerminalSessionProcess = .registered(.init(pid: claudePID, procStart: claudeStart)),
                    observed: TerminalProcessObservation? = TerminalProcessObservation(pid: claudePID, procStart: claudeStart,
                                                                                       tty: "ttys005"),
                    switches hostSwitches: TerminalHostSwitches = switches([.terminalApp]),
                    inventories: [TerminalHost: TerminalHostInventory] = [.terminalApp: .tabs([claudeTab()])],
                    processes: [String: [TerminalProcess]] = [claudeTTY: TerminalForegroundProcesses.parse(claudePS)!])
    -> TerminalTabBinding {
    TerminalTabBindingRules.claude(sessionID: claudeSession, liveness: liveness, process: process, observed: observed,
                                   switches: hostSwitches, inventories: inventories, processes: processes)
}

@Test func claudeFollowsItsRegistryProcessToTheOneTabOnItsTTY() {
    let bound = TerminalTabBinding.bound(TerminalTabTarget(host: .terminalApp, tabID: "window 9882", tty: claudeTTY))
    #expect(claude() == bound)
    // The title is not required: WezTerm can hide it behind an earlier OSC 1 icon title.
    #expect(claude(inventories: [.terminalApp: .tabs([claudeTab(title: "-zsh")])]) == bound)
}

@Test func aReusedPIDWhoseStartDiffersFromProcStartNeverBinds() {
    let reused = TerminalProcessObservation(pid: claudePID, procStart: "Mon Oct 12 09:44:51 2026", tty: "ttys005")
    #expect(claude(observed: reused) == .unavailable(.processStartMismatch))
    #expect(claude(observed: TerminalProcessObservation(pid: claudePID, procStart: nil, tty: "ttys005"))
        == .unavailable(.processStartMismatch))
    #expect(claude(observed: nil) == .unavailable(.processEnded))
    // Without a recorded `procStart` the live PID is accepted, as ADR 0008's registry read does.
    #expect(claude(process: .registered(.init(pid: claudePID, procStart: nil)))
        == .bound(TerminalTabTarget(host: .terminalApp, tabID: "window 9882", tty: claudeTTY)))
}

@Test func aTabTitleNamingAnotherSessionVetoesClaude() {
    let otherClaude = claudeTab(title: "Herdly Claude 0b8d7c66-1a2b-4c3d-8e9f-0a1b2c3d4e5f")
    #expect(claude(inventories: [.terminalApp: .tabs([otherClaude])]) == .unavailable(.conflictingTitle))
    let codexIdentifier = claudeTab(title: codexTitle)
    #expect(claude(inventories: [.terminalApp: .tabs([codexIdentifier])]) == .unavailable(.conflictingTitle))
}

@Test func anUnreadableHostDoesNotStopAClaudeSessionAReadableHostHolds() {
    // ADR 0013, 2026-11-25: the process's tty is one terminal's, so Terminal.app's tab on it binds whatever
    // an unreadable iTerm2 holds.
    let both = switches([.terminalApp, .iTerm2])
    #expect(claude(switches: both, inventories: [.terminalApp: .tabs([claudeTab()]), .iTerm2: .unreadable])
        == .bound(TerminalTabTarget(host: .terminalApp, tabID: "window 9882", tty: claudeTTY)))
    // No readable host holds the tty: the unreadable one may, so the session stays unavailable.
    #expect(claude(switches: both, inventories: [.terminalApp: .tabs([claudeTab(tty: "/dev/ttys099")]), .iTerm2: .unreadable])
        == .unavailable(.hostUnreadable(.iTerm2)))
    // An enabled host never read yet counts as unreadable too.
    #expect(claude(switches: both, inventories: [.terminalApp: .tabs([])]) == .unavailable(.hostUnreadable(.iTerm2)))
}

@Test func claudeFailsClosedWithoutExactlyOneForegroundTabForItsProcess() {
    #expect(claude(liveness: .ended) == .unavailable(.sessionEnded))
    #expect(claude(process: .unidentified) == .unavailable(.processUnidentified))
    #expect(claude(process: .ambiguous) == .unavailable(.processAmbiguous))
    #expect(claude(observed: TerminalProcessObservation(pid: claudePID, procStart: claudeStart, tty: nil))
        == .unavailable(.noTerminal))
    // On a tty no enabled host lists: a herdr pane, or a switched-off app.
    #expect(claude(inventories: [.terminalApp: .tabs([claudeTab(tty: "/dev/ttys040")])])
        == .unavailable(.ttyNotInEnabledHost))
    #expect(claude(switches: switches([.terminalApp, .wezTerm]),
                   inventories: [.terminalApp: .tabs([claudeTab()]), .wezTerm: .tabs([claudeTab("3")])])
        == .unavailable(.duplicateTTYs(2)))
    #expect(claude(inventories: [.terminalApp: .tabs([claudeTab(panes: 2)])]) == .unavailable(.split))
    // A shell got the terminal back while Claude was suspended.
    let suspended = """
    70410 Ss     login
    70412 T      /Users/test/.local/share/claude/versions/2.1.296
    70415 S+     -zsh
    """
    #expect(claude(processes: [claudeTTY: TerminalForegroundProcesses.parse(suspended)!])
        == .unavailable(.agentProcessNotInForeground))
    #expect(claude(processes: [:]) == .unavailable(.processesUnreadable))
}
