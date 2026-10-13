import Foundation
import Testing
@testable import SteerCore

// Terminal.app (#239). Fixtures follow the saved output of the live proof
// (docs/evidence/terminal-app-live.md, terminal-app-live.json): a ⌘T tab group whose tabs are each
// their own scripting window (9882, 9921, 9923) plus a separate window 9935, front window first.
// Codex's OSC 0 title and Steer's Claude title show exactly in `custom title`; a plain shell shows
// "Terminal".

private let codexSession = UUID(uuidString: "01A129B8-E8DD-7821-BABB-CDC0EFB2CEF6")!
private let codexTitle = "01a129b8-e8dd-7821-babb-cdc0e..."
private let claudeSessionID = "12e2faa8-6707-4877-97e2-ab6ee14acaaa"
private let claudeTitle = "Steer Claude 12e2faa8-6707-4877-97e2-ab6ee14acaaa"

/// What Steer's `TerminalApp.js` inventory returns for the proof's four tabs, T1 in front.
private let inventoryJSON = """
{"status":"ok","windows":[
 {"id":9882,"tabs":[{"tty":"/dev/ttys005","title":"\(codexTitle)"}]},
 {"id":9921,"tabs":[{"tty":"/dev/ttys017","title":"\(claudeTitle)"}]},
 {"id":9923,"tabs":[{"tty":"/dev/ttys018","title":"Terminal"}]},
 {"id":9935,"tabs":[{"tty":"/dev/ttys019","title":"Terminal"}]}
]}
"""

private func snapshot(_ json: String = inventoryJSON) -> TerminalAppSnapshot? {
    TerminalAppSnapshot.parse(Data(json.utf8))
}

private func tab(_ window: Int, _ tty: String, _ title: String?) -> TerminalTab {
    TerminalTab(tabID: String(window), tty: tty, title: title, paneCount: 1)
}

// MARK: - Inventory

@Test func terminalAppInventoryListsEachTabWindowWithItsTTYAndCustomTitle() throws {
    let parsed = try #require(snapshot())
    #expect(parsed.frontWindowID == 9882)
    #expect(parsed.inventory == .tabs([
        tab(9882, "/dev/ttys005", codexTitle),
        tab(9921, "/dev/ttys017", claudeTitle),
        tab(9923, "/dev/ttys018", "Terminal"),
        tab(9935, "/dev/ttys019", "Terminal"),
    ]))
}

@Test func terminalAppInventoryWithNoWindowsHoldsNoTab() throws {
    let parsed = try #require(snapshot(#"{"status":"ok","windows":[]}"#))
    #expect(parsed.inventory == .tabs([]))
    #expect(parsed.frontWindowID == nil)
}

@Test func terminalAppInventoryRefusesMalformedOrOversizedReplies() {
    // Not ok, wrong types, a bad tty, a non-positive window id, a missing field: unreadable, never repaired.
    #expect(snapshot(#"{"status":"error","windows":[]}"#) == nil)
    #expect(snapshot(#"{"status":"ok","windows":[{"id":"9882","tabs":[]}]}"#) == nil)
    #expect(snapshot(#"{"status":"ok","windows":[{"id":0,"tabs":[]}]}"#) == nil)
    #expect(snapshot(#"{"status":"ok","windows":[{"id":5,"tabs":[{"tty":"/dev/console","title":"x"}]}]}"#) == nil)
    #expect(snapshot(#"{"status":"ok","windows":[{"id":5,"tabs":[{"title":"x"}]}]}"#) == nil)
    #expect(snapshot("not json") == nil)
    let long = String(repeating: "a", count: TerminalAppSnapshot.maximumTitleLength + 1)
    #expect(snapshot(#"{"status":"ok","windows":[{"id":5,"tabs":[{"tty":"/dev/ttys001","title":"\#(long)"}]}]}"#) == nil)
    let many = (1...(TerminalAppSnapshot.maximumWindows + 1)).map { #"{"id":\#($0),"tabs":[]}"# }.joined(separator: ",")
    #expect(snapshot(#"{"status":"ok","windows":[\#(many)]}"#) == nil)
    #expect(TerminalAppSnapshot.parse(Data(count: TerminalAppSnapshot.maximumReplySize + 1)) == nil)
}

@Test func terminalAppTitleMayBeMissingButATTYMayNot() throws {
    // A tab whose custom title cannot be read still holds its tty: Claude binds by tty alone.
    let parsed = try #require(snapshot(#"{"status":"ok","windows":[{"id":7,"tabs":[{"tty":"ttys003","title":null}]}]}"#))
    #expect(parsed.inventory == .tabs([tab(7, "/dev/ttys003", nil)]))
}

@Test func aScriptingWindowHoldingSeveralTabsKeepsEachTabsTTY() throws {
    // Older window tabbing lists several tabs in one window. Each tab is still one pane on its own tty,
    // so it binds; Open cannot pick a tab inside it (`selected` did nothing live) and falls back.
    let parsed = try #require(snapshot(#"""
    {"status":"ok","windows":[{"id":40,"tabs":[{"tty":"/dev/ttys001","title":"a"},{"tty":"/dev/ttys002","title":"b"}]}]}
    """#))
    #expect(parsed.inventory == .tabs([tab(40, "/dev/ttys001", "a"), tab(40, "/dev/ttys002", "b")]))
    #expect(parsed.tabsInWindow(40) == 2)
}

@Test func onlyTabsThatCouldBindAreReadWithPs() throws {
    // A shortened Codex title, or a Claude process's tty; never a plain shell tab.
    let parsed = try #require(snapshot())
    #expect(parsed.ttysToRead(claudeTTYs: []) == ["/dev/ttys005"])
    #expect(parsed.ttysToRead(claudeTTYs: ["/dev/ttys017"]) == ["/dev/ttys005", "/dev/ttys017"])
}

// MARK: - Binding (ADR 0013) over Terminal.app inventories

private let terminalOn = TerminalHostSwitches(enabled: [.terminalApp])
private let bothOn = TerminalHostSwitches(enabled: [.terminalApp, .ghostty])

// `ps -o pid=,stat=,comm= -t` for the proof's tabs: Codex on T1, Claude on T2, `sleep` on the decoy.
private let psCodex = TerminalForegroundProcesses.parse("  812 Ss login\n60859 S+ codex\n")!
private let psClaude = TerminalForegroundProcesses.parse("  901 Ss login\n70122 S+ claude\n70130 S+ caffeinate\n")!
private let psSleep = TerminalForegroundProcesses.parse("  950 Ss login\n70400 S+ sleep\n")!

private func codexBinding(_ inventory: TerminalHostInventory, switches: TerminalHostSwitches = terminalOn,
                          extra: [TerminalHost: TerminalHostInventory] = [:],
                          processes: [String: [TerminalProcess]] = ["/dev/ttys005": psCodex, "/dev/ttys018": psSleep])
    -> TerminalTabBinding {
    var inventories = extra
    inventories[.terminalApp] = inventory
    return TerminalTabBindingRules.codex(sessionID: codexSession.uuidString, liveness: .live,
                                         liveSessions: [codexSession.uuidString], switches: switches,
                                         inventories: inventories, processes: processes, secondRead: inventories)
}

@Test func aCodexTabInTerminalAppBindsByTitleAndItsForegroundCodex() throws {
    let inventory = try #require(snapshot()).inventory
    #expect(codexBinding(inventory)
        == .bound(TerminalTabTarget(host: .terminalApp, tabID: "9882", tty: "/dev/ttys005")))
}

@Test func aDecoyCarryingCodexsTitleInTerminalAppBindsNothingAndLeavesTheRealTabBound() throws {
    // T3's custom title became Codex's exact title over `sleep` in the live proof. It runs no `codex`, so it
    // is no candidate and the real tab binds (#268).
    let decoy = inventoryJSON.replacingOccurrences(of: #""tty":"/dev/ttys018","title":"Terminal""#,
                                                   with: #""tty":"/dev/ttys018","title":"\#(codexTitle)""#)
    let inventory = try #require(snapshot(decoy)).inventory
    #expect(codexBinding(inventory) == .bound(TerminalTabTarget(host: .terminalApp, tabID: "9882", tty: "/dev/ttys005")))
    // With the real tab closed, the decoy alone binds nothing: no tab running `codex` carries the title.
    let alone = decoy.replacingOccurrences(of: #""tty":"/dev/ttys005","title":"\#(codexTitle)""#,
                                           with: #""tty":"/dev/ttys005","title":"Terminal""#)
    #expect(codexBinding(try #require(snapshot(alone)).inventory) == .unavailable(.titleNotFound))
}

@Test func aClaudeTabInTerminalAppBindsByItsProcessesTTY() throws {
    let inventory = try #require(snapshot()).inventory
    let binding = TerminalTabBindingRules.claude(
        sessionID: claudeSessionID, liveness: .live,
        process: .registered(ClaudeSessionRegistry.Process(pid: 70122, procStart: nil)),
        observed: TerminalProcessObservation(pid: 70122, procStart: nil, tty: "ttys017"),
        switches: terminalOn, inventories: [.terminalApp: inventory], processes: ["/dev/ttys017": psClaude])
    #expect(binding == .bound(TerminalTabTarget(host: .terminalApp, tabID: "9921", tty: "/dev/ttys017")))
}

@Test func anUnreadableOrUnreadTerminalAppLeavesEverySessionUnavailable() {
    #expect(codexBinding(.unreadable) == .unavailable(.hostUnreadable(.terminalApp)))
    // A Terminal.app that is not running holds nothing.
    #expect(codexBinding(.notRunning) == .unavailable(.titleNotFound))
    // Switched off, it is never read whatever it holds.
    #expect(codexBinding(.unreadable, switches: TerminalHostSwitches()) == .unavailable(.titleNotFound))
}

// MARK: - Visible (ADR 0016)

private let t1 = TerminalTabTarget(host: .terminalApp, tabID: "9882", tty: "/dev/ttys005")
private let t2 = TerminalTabTarget(host: .terminalApp, tabID: "9921", tty: "/dev/ttys017")

@Test func terminalAppsFrontTabWindowIsVisibleOnlyWhenMacOSAndTheWindowServerAgree() throws {
    let parsed = try #require(snapshot())
    #expect(TerminalVisibility.terminalApp(parsed, frontmost: .terminalApp, onScreenWindowIDs: [9882]) == .visible(t1))
    // Finder in front: Terminal still reports its last front window, which is not enough.
    #expect(TerminalVisibility.terminalApp(parsed, frontmost: nil, onScreenWindowIDs: [9882]) == .nothing)
    #expect(TerminalVisibility.terminalApp(parsed, frontmost: .ghostty, onScreenWindowIDs: [9882]) == .nothing)
    // The front window is not listed on screen (another Space).
    #expect(TerminalVisibility.terminalApp(parsed, frontmost: .terminalApp, onScreenWindowIDs: [9921]) == .nothing)
    // Unread inventory or window list: nothing is known.
    #expect(TerminalVisibility.terminalApp(nil, frontmost: .terminalApp, onScreenWindowIDs: [9882]) == .unknown)
    #expect(TerminalVisibility.terminalApp(parsed, frontmost: .terminalApp, onScreenWindowIDs: nil) == .unknown)
}

@Test func aFrontWindowHoldingSeveralTabsIsNeverAVisibleTarget() throws {
    let parsed = try #require(snapshot(#"""
    {"status":"ok","windows":[{"id":40,"tabs":[{"tty":"/dev/ttys001","title":"a"},{"tty":"/dev/ttys002","title":"b"}]}]}
    """#))
    #expect(TerminalVisibility.terminalApp(parsed, frontmost: .terminalApp, onScreenWindowIDs: [40]) == .nothing)
}

// MARK: - Open (ADR 0015, ADR 0016)

@Test func terminalAppOpenPlansOnlyAnExactTabWindow() throws {
    let parsed = try #require(snapshot())
    #expect(TerminalAppOpen.plan(.bound(t1), snapshot: parsed) == .success(t1))
    // A bound tab inside a window of several tabs cannot be picked: it falls back.
    let shared = try #require(snapshot(#"""
    {"status":"ok","windows":[{"id":9882,"tabs":[{"tty":"/dev/ttys005","title":"x"},{"tty":"/dev/ttys002","title":"b"}]}]}
    """#))
    #expect(TerminalAppOpen.plan(.bound(t1), snapshot: shared)
        == .failure(.fallBack(.unsupportedLayout, candidates: 1)))
}

@Test func aSessionNoTerminalAppTabHoldsKeepsTheOtherHostsRoutes() throws {
    let tabs = try #require(snapshot()).inventory
    // Another route on (Ghostty's title route, iTerm2's cross-host Open, or Claude's own process) and
    // Terminal.app not holding the session, or not running: that route decides.
    #expect(TerminalAppOpen.leavesToOtherRoute(otherRouteOn: true, inventory: tabs, holdsSession: false))
    #expect(TerminalAppOpen.leavesToOtherRoute(otherRouteOn: true, inventory: .notRunning, holdsSession: false))
    // Held by Terminal.app, no other route, or Terminal.app unreadable (every session unavailable, ADR 0013).
    #expect(!TerminalAppOpen.leavesToOtherRoute(otherRouteOn: true, inventory: tabs, holdsSession: true))
    #expect(!TerminalAppOpen.leavesToOtherRoute(otherRouteOn: false, inventory: tabs, holdsSession: false))
    #expect(!TerminalAppOpen.leavesToOtherRoute(otherRouteOn: true, inventory: .unreadable, holdsSession: false))
}

@Test func terminalAppRaiseReplyDecidesUnavailableOrFallback() {
    #expect(TerminalAppOpen.raised(.reply(Data(#"{"status":"ok"}"#.utf8))) == nil)
    // Automation denied: unavailable, because raising the app would hide a fix the user must make.
    #expect(TerminalAppOpen.raised(.denied) == .unavailable(.hostUnreadable(.terminalApp)))
    // The tab-window is gone (the stale reference of the live proof): unavailable.
    #expect(TerminalAppOpen.raised(.reply(Data(#"{"status":"gone"}"#.utf8))) == .unavailable(.sessionEnded))
    // The tab moved to another window, its window gained a tab, or its tty shows twice: a layout
    // change, which falls back rather than claiming the session ended.
    #expect(TerminalAppOpen.raised(.reply(Data(#"{"status":"moved"}"#.utf8))) == .fallBack(.unsupportedLayout, candidates: 1))
    // Any other error, or an unknown reply, falls back.
    #expect(TerminalAppOpen.raised(.failed) == .fallBack(.notVerified, candidates: 1))
    #expect(TerminalAppOpen.raised(.reply(Data("garbage".utf8))) == .fallBack(.notVerified, candidates: 1))
}

@Test func terminalAppOpenVerifiesTheTargetIsVisibleAfterRaising() throws {
    let parsed = try #require(snapshot())
    #expect(TerminalAppOpen.verified(t1, snapshot: parsed, frontmost: .terminalApp, onScreenWindowIDs: [9882]) == nil)
    // Another tab of the group in front, Terminal not frontmost, or no read: the app is raised already,
    // so the Open falls back and acknowledges nothing.
    #expect(TerminalAppOpen.verified(t2, snapshot: parsed, frontmost: .terminalApp, onScreenWindowIDs: [9882])
        == .fallBack(.notVerified, candidates: 1))
    #expect(TerminalAppOpen.verified(t1, snapshot: parsed, frontmost: nil, onScreenWindowIDs: [9882])
        == .fallBack(.notVerified, candidates: 1))
    #expect(TerminalAppOpen.verified(t1, snapshot: nil, frontmost: .terminalApp, onScreenWindowIDs: [9882])
        == .fallBack(.notVerified, candidates: 1))
}

@Test func terminalAppOpenSequenceAcknowledgesOnlyAVerifiedOpen() async throws {
    let parsed = try #require(snapshot())
    var raised = 0
    func steps(raise reply: TerminalAppScriptResult, front: TerminalHost?) -> TerminalOpenSteps<TerminalTabTarget, OpenMiss> {
        TerminalOpenSteps(now: { 100 },
                          revalidate: { _ in TerminalAppOpen.plan(.bound(t1), snapshot: parsed) },
                          raise: { _ in raised += 1; return TerminalAppOpen.raised(reply) },
                          verify: { TerminalAppOpen.verified($0, snapshot: parsed, frontmost: front, onScreenWindowIDs: [9882]) })
    }
    let ok = Data(#"{"status":"ok"}"#.utf8)
    #expect(await TerminalOpenSequence.run(steps(raise: .reply(ok), front: .terminalApp)) == .opened(t1, preOpenAt: 100))
    #expect(await TerminalOpenSequence.run(steps(raise: .reply(ok), front: nil))
        == .failed(.fallBack(.notVerified, candidates: 1), at: .verify))
    #expect(await TerminalOpenSequence.run(steps(raise: .denied, front: .terminalApp))
        == .failed(.unavailable(.hostUnreadable(.terminalApp)), at: .raise))
    // Each run raised once and never retried.
    #expect(raised == 3)
}

@Test func codexFallbackCandidatesAreTheTitledTabsOfEnabledHostsAndTheirOneForegroundCodex() throws {
    let decoy = inventoryJSON.replacingOccurrences(of: #""tty":"/dev/ttys018","title":"Terminal""#,
                                                   with: #""tty":"/dev/ttys018","title":"\#(codexTitle)""#)
    let inventory = try #require(snapshot(decoy)).inventory
    let ghostty = TerminalHostInventory.ghosttyTitles(ghosttySnapshot(titles: [codexTitle]), running: true)
    let carriers = TerminalTabOpen.codexCarriers(title: codexTitle, switches: bothOn,
                                                 inventories: [.terminalApp: inventory, .ghostty: ghostty],
                                                 processes: ["/dev/ttys005": psCodex, "/dev/ttys018": psSleep])
    // The walk starts from each Terminal.app tab's single foreground `codex`; the decoy has none, so it is
    // skipped (ADR 0015's 2026-10-13 amendment, #268).
    #expect(carriers == [TerminalCodexCarrier(host: .ghostty, tty: nil, codexPID: nil),
                         TerminalCodexCarrier(host: .terminalApp, tty: "/dev/ttys005", codexPID: 60859)])
    // Only a switched-on host contributes: a session in a switched-off app has no candidate.
    #expect(TerminalTabOpen.codexCarriers(title: codexTitle, switches: terminalOn,
                                          inventories: [.terminalApp: inventory, .ghostty: ghostty],
                                          processes: [:]).count == 2)
}

// MARK: - Card lines (docs/product.md, "Agreed terminal host presentation")

@Test func terminalAppOpenUnavailableLinesNameTheApp() {
    #expect(OpenUnavailableReason.hostUnreadable(.terminalApp).cardLine
        == "Steer can't read Terminal.app. Check Settings › Terminals.")
    #expect(OpenUnavailableReason.appNotRunning(.terminalApp).cardLine == "Terminal.app isn't running.")
}

@Test func terminalAppSettingsCardFollowsTheSwitchPermissionAndScan() {
    let off = TerminalAppPresentation.settingsRow(on: false, access: nil, readable: nil, sessionsSeen: false)
    #expect(off.badge == .off && off.problems.isEmpty)
    #expect(off.detail == "Steer never scans or contacts Terminal.app.")
    #expect(off.permission == "Not verified")
    let unused = TerminalAppPresentation.settingsRow(on: true, access: .granted, readable: true, sessionsSeen: false)
    #expect(unused.badge == .notInUse && unused.permission == "Allowed")
    let ready = TerminalAppPresentation.settingsRow(on: true, access: .granted, readable: true, sessionsSeen: true)
    #expect(ready.badge == .ready && ready.problems.isEmpty)
    // Denied, or running but unreadable: needs attention, with the fix on its own line.
    let denied = TerminalAppPresentation.settingsRow(on: true, access: .denied, readable: nil, sessionsSeen: true)
    #expect(denied.badge == .needsAttention && denied.permission == "Not allowed")
    #expect(denied.problems == [TerminalAppPresentation.unreadableLine])
    let unreadable = TerminalAppPresentation.settingsRow(on: true, access: .granted, readable: false, sessionsSeen: false)
    #expect(unreadable.badge == .needsAttention && unreadable.problems == [TerminalAppPresentation.unreadableLine])
    // The footer explains the silent fallback and the typed-input rule.
    #expect(TerminalAppPresentation.footer
        == "Steer returns to unsplit tabs; otherwise Open raises Terminal.app. Replies are typed into the exact tab; Codex questions are answered in Codex.")
}

// MARK: - Ghostty beside Terminal.app

private func ghosttySnapshot(titles: [String], tty: String? = nil) -> GhosttySnapshot {
    let tabs = titles.enumerated().map { index, title in
        var terminal: [String: Any] = ["id": "term-\(index)", "name": title]
        if let tty { terminal["tty"] = tty }
        return ["id": "tab-\(index)", "terminals": [terminal]] as [String: Any]
    }
    let object: [String: Any] = ["status": "ok", "windows": [["id": "win-1", "tabs": tabs]],
                                 "front_window_id": "win-1"]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return try! JSONDecoder().decode(GhosttySnapshot.self, from: data)
}

@Test func ghosttysTitleOnlyTabsCountTowardCodexTitleUniqueness() throws {
    let terminal = try #require(snapshot()).inventory
    // The same title in a Ghostty tab without `tty` makes two candidates across the enabled hosts.
    let ghostty = TerminalHostInventory.ghosttyTitles(ghosttySnapshot(titles: [codexTitle]), running: true)
    #expect(codexBinding(terminal, switches: bothOn, extra: [.ghostty: ghostty]) == .unavailable(.duplicateTitles(2)))
    // A session only in Ghostty is left to Ghostty's own title route.
    let empty = try #require(snapshot(#"{"status":"ok","windows":[]}"#)).inventory
    #expect(codexBinding(empty, switches: bothOn, extra: [.ghostty: ghostty]) == .unavailable(.ttyUnknown(.ghostty)))
}
