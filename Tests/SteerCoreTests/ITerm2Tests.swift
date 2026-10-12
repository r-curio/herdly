import Foundation
import Testing
@testable import SteerCore

// iTerm2 Open (#238). Fixtures are what the bundled ITerm2.js reports, modeled on the third full run
// of the live proof (docs/evidence/iterm2-live.md, iterm2-live.json): window A (9592) with A1 (Codex),
// A2 (Claude), A3 (a decoy carrying Codex's title over `sleep`) and A4 (split into A4a and A4b), and
// window B (9593) with one shell, B1, current while Finder is in front.

private let codexSession = "01a12976-3c08-7733-990a-4d8a574a90dc"
private let codexTitle = "01a12976-3c08-7733-990a-4d8a5..."
private let claudeSession = "1013bfc3-fba4-49fb-b99d-ae8774677404"
private let a1 = "BC81E3A6-3EA9-4431-9F0E-B3878AEC3157"
private let a2 = "2EDA6BF5-855A-4425-A1D3-A905E8F68778"
private let a3 = "655BB60C-BF13-4044-90FB-32A8DAEF156B"
private let a4a = "7BC6168D-0880-4F07-BF24-E39C1356971E"
private let a4b = "0E6F2801-7953-4B2A-A213-ACD7377B69F8"
private let b1 = "DB978EE1-01BB-4FE6-9F82-88B775105CDC"

/// ITerm2.js `snapshot` output. Codex's OSC 0 title shows in both title variables; Steer's Claude
/// title (OSC 2) only in the window name; the decoy A3 copies Codex's title exactly.
private func snapshotJSON(current: String = b1, currentWindow: Int = 9593, a1Title: String? = codexTitle,
                          a3Title: String? = codexTitle, a1TTY: String = "/dev/ttys030", a4Split: Bool = true) -> String {
    func session(_ id: String, _ tty: String, _ window: String?, _ icon: String?) -> String {
        let w = window.map { "\"\($0)\"" } ?? "null", i = icon.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(id)","tty":"\#(tty)","window_name":\#(w),"icon_name":\#(i)}"#
    }
    let a4 = a4Split ? session(a4a, "/dev/ttys033", nil, nil) + "," + session(a4b, "/dev/ttys034", nil, nil)
                     : session(a4a, "/dev/ttys033", nil, nil)
    return """
    {"status":"ok","current":{"window":\(currentWindow),"session":"\(current)"},"windows":[
     {"id":9593,"tabs":[{"sessions":[\(session(b1, "/dev/ttys035", nil, nil))]}]},
     {"id":9592,"tabs":[
      {"sessions":[\(session(a1, a1TTY, a1Title, a1Title))]},
      {"sessions":[\(session(a2, "/dev/ttys031", "Steer Claude \(claudeSession)", nil))]},
      {"sessions":[\(session(a3, "/dev/ttys032", a3Title, a3Title))]},
      {"sessions":[\(a4)]}]}]}
    """
}

private func snapshot(_ json: String = snapshotJSON()) -> ITerm2Snapshot? {
    guard case .snapshot(let value)? = ITerm2Reading.parse(Data(json.utf8)) else { return nil }
    return value
}

// MARK: - Inventory

@Test func iTerm2InventoryListsEverySessionWithItsTTYTitleAndPaneCount() throws {
    let parsed = try #require(snapshot())
    guard case .tabs(let tabs) = parsed.inventory else { Issue.record("expected tabs"); return }
    #expect(tabs.count == 6)
    #expect(tabs.contains(TerminalTab(tabID: a1, tty: "/dev/ttys030", title: codexTitle, paneCount: 1)))
    // Claude's OSC 2 title is only in the window name.
    #expect(tabs.contains(TerminalTab(tabID: a2, tty: "/dev/ttys031", title: "Steer Claude \(claudeSession)", paneCount: 1)))
    // Both halves of a split report the tab's session count.
    #expect(tabs.contains(TerminalTab(tabID: a4a, tty: "/dev/ttys033", title: nil, paneCount: 2)))
    #expect(tabs.contains(TerminalTab(tabID: a4b, tty: "/dev/ttys034", title: nil, paneCount: 2)))
    #expect(parsed.current == ITerm2Current(window: 9593, session: b1))
}

@Test func aMalformedOrPartialITerm2InventoryIsUnreadableNeverPartial() {
    let malformed = [
        "not json",
        #"{"status":"error","message":"Not authorized to send Apple events to iTerm2."}"#,
        #"{"status":"ok"}"#,
        snapshotJSON().replacingOccurrences(of: "/dev/ttys031", with: "/dev/console"),
        snapshotJSON().replacingOccurrences(of: a3, with: a1),
        snapshotJSON().replacingOccurrences(of: #""id":9593"#, with: #""id":"9593""#),
        snapshotJSON().replacingOccurrences(of: a2, with: "not-a-guid"),
        #"{"status":"ok","current":null,"windows":[{"id":1,"tabs":[{"sessions":null}]}]}"#,
        #"{"status":"unknown"}"#,
        // A title of the wrong type is malformed, not a missing title.
        snapshotJSON().replacingOccurrences(of: #""window_name":"Steer Claude \#(claudeSession)""#, with: #""window_name":7"#),
        snapshotJSON().replacingOccurrences(of: #""icon_name":null"#, with: #""icon_name":["x"]"#),
    ]
    for json in malformed { #expect(ITerm2Reading.parse(Data(json.utf8)) == nil, "\(json.prefix(80))") }
    #expect(ITerm2Reading.parse(Data(repeating: 0x20, count: ITerm2Reading.maximumBytes + 1)) == nil)
    #expect(ITerm2Reading.parse(Data(#"{"status":"not_running"}"#.utf8)) == .notRunning)
    // No windows and no current session is a complete, empty inventory; so is a tab left with no
    // sessions after its processes ended (the proof's teardown hazard).
    #expect(ITerm2Reading.parse(Data(#"{"status":"ok","current":null,"windows":[]}"#.utf8))
            == .snapshot(ITerm2Snapshot(sessions: [], current: nil)))
    #expect(ITerm2Reading.parse(Data(#"{"status":"ok","current":null,"windows":[{"id":1,"tabs":[{"sessions":[]}]}]}"#.utf8))
            == .snapshot(ITerm2Snapshot(sessions: [], current: nil)))
}

private let iTerm2Script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Sources/SteerApp/Resources/ITerm2.js")

// The smoke test never runs the bundled script; compiling it catches a syntax error without sending
// any Apple Event. ADR 0017 and ADR 0013: it never writes text and never reads `jobName`.
@Test func bundledITerm2ScriptCompilesAndNeverTypesOrReadsJobName() throws {
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("iterm2-\(UUID().uuidString).scpt")
    defer { try? FileManager.default.removeItem(at: output) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
    process.arguments = ["-l", "JavaScript", "-o", output.path, iTerm2Script.path]
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "\(message)")
    let source = try String(contentsOf: iTerm2Script, encoding: .utf8)
    for forbidden in [".write(", "'jobName'", "\"jobName\"", "launch(", "deepestJob"] {
        #expect(!source.contains(forbidden), "\(forbidden)")
    }
}

// MARK: - Binding (ADR 0013) over iTerm2's inventory

private let onlyITerm2 = TerminalHostSwitches(enabled: [.iTerm2])

/// `ps -o pid=,stat=,comm= -t` per tty, as the proof's `ps_foreground` rows report them.
private let processes: [String: [TerminalProcess]] = [
    "/dev/ttys030": TerminalForegroundProcesses.parse("6082 Ss login\n6090 S+ codex\n")!,
    "/dev/ttys031": TerminalForegroundProcesses.parse("6088 Ss login\n6095 S+ claude\n6101 S+ caffeinate\n")!,
    "/dev/ttys032": TerminalForegroundProcesses.parse("6093 Ss login\n6099 S+ sleep\n")!,
    "/dev/ttys033": TerminalForegroundProcesses.parse("6110 Ss+ -zsh\n")!,
]

private func codexBinding(_ json: String, second: String? = nil) -> TerminalTabBinding {
    let first = snapshot(json)?.inventory ?? .unreadable
    let again = snapshot(second ?? json)?.inventory ?? .unreadable
    return TerminalTabBindingRules.codex(sessionID: codexSession, liveness: .live, liveSessions: [codexSession],
                                         switches: onlyITerm2, inventories: [.iTerm2: first], processes: processes,
                                         secondRead: [.iTerm2: again])
}

private func claudeBinding(_ json: String, pid: Int32 = 6095, tty: String = "/dev/ttys031") -> TerminalTabBinding {
    TerminalTabBindingRules.claude(sessionID: claudeSession, liveness: .live,
                                   process: .registered(.init(pid: pid, procStart: nil)),
                                   observed: TerminalProcessObservation(pid: pid, procStart: nil, tty: tty),
                                   switches: onlyITerm2, inventories: [.iTerm2: snapshot(json)?.inventory ?? .unreadable],
                                   processes: processes)
}

@Test func codexBindsToItsITerm2SessionOnlyWithoutTheDecoy() {
    // The decoy copies the title exactly, so a title alone never picks a tab.
    #expect(codexBinding(snapshotJSON()) == .unavailable(.duplicateTitles(2)))
    #expect(codexBinding(snapshotJSON(a3Title: nil)) == .bound(TerminalTabTarget(host: .iTerm2, tabID: a1, tty: "/dev/ttys030")))
    // The decoy alone, its title over `sleep`: no foreground `codex`.
    #expect(codexBinding(snapshotJSON(a1Title: nil)) == .unavailable(.foregroundProcesses(count: 0)))
    // A second read in which the tab moved to another tty.
    #expect(codexBinding(snapshotJSON(a3Title: nil), second: snapshotJSON(a3Title: nil, a1TTY: "/dev/ttys040"))
            == .unavailable(.titleChanged))
}

@Test func claudeBindsToItsITerm2SessionByTTYAndASplitNeverBinds() {
    #expect(claudeBinding(snapshotJSON()) == .bound(TerminalTabTarget(host: .iTerm2, tabID: a2, tty: "/dev/ttys031")))
    // A Claude in one half of the split tab A4.
    #expect(claudeBinding(snapshotJSON(), pid: 6110, tty: "/dev/ttys033") == .unavailable(.split))
    // An unreadable iTerm2 rules nothing out.
    #expect(claudeBinding("garbage") == .unavailable(.hostUnreadable(.iTerm2)))
}

@Test func onlyTabsThatCanHoldATrackedSessionHaveTheirProcessesRead() throws {
    let parsed = try #require(snapshot())
    // Codex titles are matched exactly; Claude ttys come from each registered process.
    #expect(parsed.ttysToRead(codexTitles: [codexTitle], claudeTTYs: ["/dev/ttys031", "ttys099"])
            == ["/dev/ttys030", "/dev/ttys031", "/dev/ttys032"])
    #expect(parsed.ttysToRead(codexTitles: [], claudeTTYs: []).isEmpty)
}

@Test func ghosttyCountsTowardCodexTitleUniquenessWithoutATTY() throws {
    let json = #"{"status":"ok","windows":[{"id":"w1","tabs":[{"id":"t1","terminals":[{"id":"p1","name":"\#(codexTitle)"},{"id":"p2","name":"zsh"}]}]}],"front_window_id":"w1","selected":null}"#
    let ghostty = try JSONDecoder().decode(GhosttySnapshot.self, from: Data(json.utf8))
    #expect(TerminalHostInventory.ghosttyTitles(ghostty, running: true)
            == .tabs([TerminalTab(tabID: "p1", tty: nil, title: codexTitle, paneCount: 2),
                      TerminalTab(tabID: "p2", tty: nil, title: "zsh", paneCount: 2)]))
    #expect(TerminalHostInventory.ghosttyTitles(nil, running: true) == .unreadable)
    #expect(TerminalHostInventory.ghosttyTitles(nil, running: false) == .notRunning)
    // With iTerm2 on too, Codex's title in a Ghostty tab and the decoy-free iTerm2 tab collide.
    let both: [TerminalHost: TerminalHostInventory] = [.iTerm2: snapshot(snapshotJSON(a3Title: nil))!.inventory,
                                                      .ghostty: TerminalHostInventory.ghosttyTitles(ghostty, running: true)]
    #expect(TerminalTabBindingRules.codex(sessionID: codexSession, liveness: .live, liveSessions: [codexSession],
                                          switches: TerminalHostSwitches(enabled: [.iTerm2, .ghostty]),
                                          inventories: both, processes: processes, secondRead: both)
            == .unavailable(.duplicateTitles(2)))
}

// MARK: - Visible (ADR 0016)

@Test func anITerm2SessionIsVisibleOnlyWhileMacOSReportsITerm2Frontmost() {
    // The proof's "focus:other-app-front": Finder in front, iTerm2 still names a current session.
    #expect(TerminalVisibility.iTerm2(snapshot(snapshotJSON(current: a4b, currentWindow: 9592)), frontmost: nil) == .nothing)
    #expect(TerminalVisibility.iTerm2(snapshot(snapshotJSON(current: a1, currentWindow: 9592)), frontmost: .ghostty) == .nothing)
    #expect(TerminalVisibility.iTerm2(snapshot(snapshotJSON(current: a1, currentWindow: 9592)), frontmost: .iTerm2) == .visible(a1))
    // No current session, or no inventory at all.
    #expect(TerminalVisibility.iTerm2(ITerm2Snapshot(sessions: [], current: nil), frontmost: .iTerm2) == .nothing)
    #expect(TerminalVisibility.iTerm2(nil, frontmost: .iTerm2) == .unknown)
}

// MARK: - Open route (ADR 0015 categories over ADR 0013's reasons)

@Test func aTabBindingRoutesOpenToTheExactTabAFallbackOrUnavailable() {
    let target = TerminalTabTarget(host: .iTerm2, tabID: a1, tty: "/dev/ttys030")
    #expect(TerminalTabOpen.route(.bound(target)) == .exact(target))
    // Ghostty without `tty` keeps its title route (ADR 0013, "Ghostty").
    #expect(TerminalTabOpen.route(.unavailable(.ttyUnknown(.ghostty))) == .ghosttyTitle)
    // Unreadable host and ended sessions stay unavailable: raising the app would hide them.
    #expect(TerminalTabOpen.route(.unavailable(.hostUnreadable(.iTerm2))) == .miss(.unavailable(.hostUnreadable(.iTerm2))))
    for ended: TerminalTabUnavailable in [.sessionEnded, .sessionNotLive, .processEnded, .processStartMismatch] {
        #expect(TerminalTabOpen.route(.unavailable(ended)) == .miss(.unavailable(.sessionEnded)), "\(ended)")
    }
    for unidentified: TerminalTabUnavailable in [.processUnidentified, .processAmbiguous] {
        #expect(TerminalTabOpen.route(.unavailable(unidentified)) == .miss(.unavailable(.appNotIdentified)), "\(unidentified)")
    }
    // No unique target or an unsupported layout falls back.
    #expect(TerminalTabOpen.route(.unavailable(.duplicateTitles(2))) == .miss(.fallBack(.noUniqueTarget, candidates: 2)))
    #expect(TerminalTabOpen.route(.unavailable(.titleNotFound)) == .miss(.fallBack(.noUniqueTarget, candidates: 0)))
    #expect(TerminalTabOpen.route(.unavailable(.split)) == .miss(.fallBack(.unsupportedLayout, candidates: 1)))
    for other: TerminalTabUnavailable in [.sessionPrefixNotUnique(2), .ttyUnknown(.iTerm2), .titleChanged,
                                          .foregroundProcesses(count: 0), .foregroundProcesses(count: 2),
                                          .processesUnreadable, .noTerminal, .ttyNotInEnabledHost, .duplicateTTYs(2),
                                          .conflictingTitle, .agentProcessNotInForeground] {
        guard case .miss(.fallBack(.noUniqueTarget, _)) = TerminalTabOpen.route(.unavailable(other)) else {
            Issue.record("\(other) should fall back"); continue
        }
    }
}

// MARK: - Open sequence (ADR 0016)

private let codexPlan = ITerm2OpenPlan(target: TerminalTabTarget(host: .iTerm2, tabID: a1, tty: "/dev/ttys030"), title: codexTitle)
private let claudePlan = ITerm2OpenPlan(target: TerminalTabTarget(host: .iTerm2, tabID: a2, tty: "/dev/ttys031"), title: nil)

/// Records every step the sequence sends, so a test can show each is sent once and in order.
@MainActor
private final class StepLog {
    var steps: [String] = []
}

@MainActor
private func runOpen(_ revalidated: Result<ITerm2OpenPlan, OpenMiss> = .success(codexPlan),
                     reply: ITerm2SelectReply = .ok,
                     after: ITerm2Snapshot? = snapshot(snapshotJSON(current: a1, currentWindow: 9592, a3Title: nil)),
                     frontmost: TerminalHost? = .iTerm2,
                     log: StepLog = StepLog()) async -> TerminalOpenRun<ITerm2OpenPlan, OpenMiss> {
    await ITerm2Open.run(now: { log.steps.append("now"); return 100 },
                         revalidate: { at in log.steps.append("revalidate@\(Int(at))"); return revalidated },
                         select: { plan in log.steps.append("select \(plan.target.tabID)"); return reply },
                         verifyRead: { log.steps.append("verify"); return (after, frontmost) })
}

@MainActor
@Test func iTerm2OpenSelectsOnceThenVerifiesTheSessionInFront() async {
    let log = StepLog()
    #expect(await runOpen(log: log) == .opened(codexPlan, preOpenAt: 100))
    #expect(log.steps == ["now", "revalidate@100", "select \(a1)", "verify"])
    // A Claude tab in the other window, renamed by the user since: still verified.
    let renamed = snapshotJSON(current: a2, currentWindow: 9592).replacingOccurrences(of: "Steer Claude \(claudeSession)", with: "notes")
    #expect(await runOpen(.success(claudePlan), after: snapshot(renamed)) == .opened(claudePlan, preOpenAt: 100))
}

@MainActor
@Test func iTerm2OpenStopsAtTheFirstFailureWithItsADR0015Category() async {
    // A miss at revalidation sends nothing to iTerm2.
    let log = StepLog()
    #expect(await runOpen(.failure(.fallBack(.unsupportedLayout, candidates: 1)), log: log)
            == .failed(.fallBack(.unsupportedLayout, candidates: 1), at: .revalidate))
    #expect(log.steps == ["now", "revalidate@100"])
    // ADR 0016: an Automation denial is unavailable; any other script error or timeout falls back.
    #expect(await runOpen(reply: .denied) == .failed(.unavailable(.hostUnreadable(.iTerm2)), at: .raise))
    #expect(await runOpen(reply: .noReply) == .failed(.fallBack(.notVerified, candidates: 1), at: .raise))
    // The session is gone: its tab closed.
    #expect(await runOpen(reply: .gone) == .failed(.unavailable(.sessionEnded), at: .raise))
    // The session's tty or layout changed under the request: iTerm2 selected nothing; fall back.
    #expect(await runOpen(reply: .changed) == .failed(.fallBack(.notVerified, candidates: 1), at: .raise))
}

@MainActor
@Test func anITerm2OpenThatDoesNotVerifyFallsBack() async {
    let notVerified = TerminalOpenRun<ITerm2OpenPlan, OpenMiss>.failed(.fallBack(.notVerified, candidates: 1), at: .verify)
    // Another app stayed in front, though iTerm2 reports the session current.
    #expect(await runOpen(frontmost: nil) == notVerified)
    // iTerm2 shows another session.
    #expect(await runOpen(after: snapshot(snapshotJSON(current: b1, a3Title: nil))) == notVerified)
    // The tab was split, the tty changed, or Codex's title changed after the selection.
    #expect(await runOpen(after: snapshot(snapshotJSON(current: a1, currentWindow: 9592, a3Title: nil, a1TTY: "/dev/ttys040")))
            == notVerified)
    #expect(await runOpen(after: snapshot(snapshotJSON(current: a1, currentWindow: 9592, a1Title: "zsh", a3Title: nil)))
            == notVerified)
    #expect(await runOpen(.success(ITerm2OpenPlan(target: TerminalTabTarget(host: .iTerm2, tabID: a4a, tty: "/dev/ttys033"),
                                                  title: nil)),
                          after: snapshot(snapshotJSON(current: a4a, currentWindow: 9592))) == notVerified)
    // The inventory after could not be read.
    #expect(await runOpen(after: nil) == notVerified)
}

@Test func onlyABindingToAnITerm2SessionBecomesAnITerm2Plan() {
    let target = TerminalTabTarget(host: .iTerm2, tabID: a1, tty: "/dev/ttys030")
    #expect(ITerm2Open.plan(.exact(target), codexTitle: codexTitle) == .success(ITerm2OpenPlan(target: target, title: codexTitle)))
    #expect(ITerm2Open.plan(.miss(.unavailable(.sessionEnded)), codexTitle: nil) == .failure(.unavailable(.sessionEnded)))
    // A tab in another host is not iTerm2's to select.
    let elsewhere = TerminalTabTarget(host: .terminalApp, tabID: "7", tty: "/dev/ttys030")
    #expect(ITerm2Open.plan(.exact(elsewhere), codexTitle: nil) == .failure(.fallBack(.noUniqueTarget, candidates: 1)))
}

// MARK: - Fallback app (ADR 0015 and its amendment)

@Test func codexFallbackCandidatesWalkFromEachTitledTabsOwnCodex() {
    let inventories: [TerminalHost: TerminalHostInventory] = [
        .iTerm2: snapshot()!.inventory,
        .ghostty: .tabs([TerminalTab(tabID: "g1", tty: nil, title: codexTitle, paneCount: 1)]),
    ]
    let switches = TerminalHostSwitches(enabled: [.iTerm2, .ghostty])
    let carriers = TerminalTabOpen.codexCarriers(title: codexTitle, switches: switches, inventories: inventories,
                                                 processes: processes)
    // A1 runs Codex; the decoy A3 has none to walk from; Ghostty's title-only tab is in Ghostty.
    #expect(Set(carriers) == [TerminalCodexCarrier(host: .iTerm2, tty: "/dev/ttys030", codexPID: 6090),
                              TerminalCodexCarrier(host: .iTerm2, tty: "/dev/ttys032", codexPID: nil),
                              TerminalCodexCarrier(host: .ghostty, tty: nil, codexPID: nil)])
    let candidates = TerminalTabOpen.codexCandidates(carriers, walk: { pid in pid == 6090 ? .reached(.iTerm2) : .failed },
                                                     ttyWrittenAt: { $0 == "/dev/ttys030" ? 50 : 10 })
    #expect(candidates.contains(CodexOpenCandidate(walk: .reached(.iTerm2), ttyWrittenAt: 50)))
    #expect(candidates.contains(CodexOpenCandidate(walk: .failed, ttyWrittenAt: 10)))
    #expect(candidates.contains(CodexOpenCandidate(walk: .reached(.ghostty), ttyWrittenAt: nil)))
    // Any candidate whose app cannot be found leaves the app unidentified: never a guess.
    #expect(OpenFallback.codexApp(candidates: candidates, switches: switches) == .failure(.appNotIdentified))
    // Without the decoy and Ghostty, the one walk names iTerm2.
    let alone = TerminalTabOpen.codexCandidates([TerminalCodexCarrier(host: .iTerm2, tty: "/dev/ttys030", codexPID: 6090)],
                                                walk: { _ in .reached(.iTerm2) }, ttyWrittenAt: { _ in nil })
    #expect(OpenFallback.codexApp(candidates: alone, switches: switches) == .success(.iTerm2))
    // A shell server reparented to launchd (iTerm2's session restoration): the walk reaches no app.
    let orphaned = TerminalTabOpen.codexCandidates([TerminalCodexCarrier(host: .iTerm2, tty: "/dev/ttys030", codexPID: 6090)],
                                                   walk: { _ in .failed }, ttyWrittenAt: { _ in nil })
    #expect(OpenFallback.codexApp(candidates: orphaned, switches: switches) == .failure(.appNotIdentified))
    // A switched-off host is never read.
    #expect(TerminalTabOpen.codexCarriers(title: codexTitle, switches: TerminalHostSwitches(enabled: [.ghostty]),
                                          inventories: inventories, processes: processes)
            == [TerminalCodexCarrier(host: .ghostty, tty: nil, codexPID: nil)])
}

// MARK: - Card lines (product.md, "Agreed terminal host presentation")

@Test func iTerm2NotchLinesNameTheAppAndNeverOfferTypedInput() {
    #expect(OpenUnavailableReason.hostUnreadable(.iTerm2).cardLine == "Steer can't read iTerm2. Check Settings › Terminals.")
    #expect(OpenUnavailableReason.appNotRunning(.iTerm2).cardLine == "iTerm2 isn't running.")
    #expect(OpenUnavailableReason.sessionEnded.cardLine == "This session has ended.")
    #expect(OpenUnavailableReason.appNotIdentified.cardLine == "Steer can't tell which terminal this session is in.")
    // ADR 0017: no question digit and no reply is ever typed into iTerm2.
    #expect(ITerm2Presentation.typedInputLine == "Steer can't type into iTerm2. Reply in the session.")
}

@Test func iTerm2SettingsCardShowsItsSwitchPermissionBadgeProblemsAndFooter() {
    func row(on: Bool = true, installed: Bool = true, access: GhosttyAutomationAccess? = .granted,
             scan: ITerm2ScanStatus = .read, inUse: Bool = true) -> ITerm2SettingsRow {
        ITerm2Presentation.settingsRow(on: on, installed: installed, access: access, scan: scan, inUse: inUse)
    }
    #expect(row(on: false) == ITerm2SettingsRow(badge: .off, permission: "Allowed", problems: []))
    #expect(row(inUse: false) == ITerm2SettingsRow(badge: .notInUse, permission: "Allowed", problems: []))
    #expect(row() == ITerm2SettingsRow(badge: .ready, permission: "Allowed", problems: []))
    // A denial turns the switch back off; the card keeps the denial and its fix.
    #expect(row(on: false, access: .denied) == ITerm2SettingsRow(badge: .off, permission: "Not allowed", problems: [.automationDenied]))
    #expect(row(access: nil, scan: .notRead, inUse: false) == ITerm2SettingsRow(badge: .notInUse, permission: "Not verified", problems: []))
    #expect(row(scan: .unreadable) == ITerm2SettingsRow(badge: .needsAttention, permission: "Allowed", problems: [.unreadable]))
    #expect(row(installed: false, access: nil, scan: .notRead, inUse: false)
            == ITerm2SettingsRow(badge: .needsAttention, permission: "Not verified", problems: [.notFound]))
    // Every problem line is its own fix.
    #expect(Set(ITerm2SettingsProblem.allCases.map(\.message)).count == ITerm2SettingsProblem.allCases.count)
    #expect(ITerm2Presentation.footer == "Steer returns to unsplit tabs; otherwise Open raises iTerm2.")
}

@Test func iTerm2SelectRepliesComeOnlyFromTheScriptsThreeStatuses() {
    #expect(ITerm2SelectReply(status: "ok") == .ok)
    #expect(ITerm2SelectReply(status: "gone") == .gone)
    #expect(ITerm2SelectReply(status: "changed") == .changed)
    // Anything else the script could say selected nothing Steer can name: it falls back.
    #expect(ITerm2SelectReply(status: "denied") == .changed)
    #expect(ITerm2SelectReply(status: "unknown") == .changed)
}

// MARK: - Typed input (ADR 0017, ADR 0013 "Freshness")

@Test func noKeyIsTypedForACodexSessionWhoseTitleIsAlsoInITerm2() {
    // The same title in a Ghostty tab and an iTerm2 tab: the title is not unique across the enabled
    // inventories, so Ghostty's relay must not type, and the card shows iTerm2's line.
    #expect(ITerm2TypedInput.codexBlock(title: codexTitle, iTerm2: snapshot()!.inventory) == .inITerm2)
    #expect(ITerm2TypedInputBlock.inITerm2.line == "Steer can't type into iTerm2. Reply in the session.")
}

@Test func anUnreadableEnabledITerm2MakesTypedInputUnavailable() {
    #expect(ITerm2TypedInput.codexBlock(title: codexTitle, iTerm2: .unreadable) == .iTerm2Unreadable)
    #expect(ITerm2TypedInputBlock.iTerm2Unreadable.line == "Steer can't reach this session's tab. Reply in the session.")
}

@Test func iTerm2OffNotRunningOrWithoutTheTitleLeavesGhosttyTypedInputUnchanged() {
    // nil: iTerm2's switch is off, so it is never read.
    #expect(ITerm2TypedInput.codexBlock(title: codexTitle, iTerm2: nil) == nil)
    #expect(ITerm2TypedInput.codexBlock(title: codexTitle, iTerm2: .notRunning) == nil)
    #expect(ITerm2TypedInput.codexBlock(title: codexTitle, iTerm2: snapshot(snapshotJSON(a1Title: nil, a3Title: nil))!.inventory) == nil)
}

// MARK: - Claude's process start (ADR 0013, ADR 0008)

@Test func aProcessStartReadsBackInClaudesProcStartLayout() throws {
    let pid = getpid()
    let start = try #require(ClaudeSessionRegistry.procStart(of: pid))
    #expect(ClaudeSessionRegistry.isRunning(.init(pid: pid, procStart: start)))
    #expect(!ClaudeSessionRegistry.isRunning(.init(pid: pid, procStart: "Thu Jan  1 00:00:00 1970")))
    #expect(ClaudeSessionRegistry.procStart(of: -1) == nil)
}
