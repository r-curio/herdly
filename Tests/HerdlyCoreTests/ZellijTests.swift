import Foundation
import Testing
@testable import HerdlyCore

// Zellij (#242). Fixtures are saved `action list-panes --json --all`, `action list-tabs --json` and
// `action list-clients` output shaped after the live proof (docs/evidence/zellij-live.md,
// zellij-live.json: session `lab`, Codex in terminal_1, Claude in terminal_2, a decoy carrying Codex's
// title in terminal_3, a split terminal_4/terminal_5, one client on /dev/ttys017) and an isolated
// Zellij 0.45.1 run on a private socket directory (the exact JSON keys, plugin panes reusing terminal
// ids, `pane_command` on terminal panes only, the suppressed `zellij:link` plugin, and `list-tabs`'
// pane counts).

private let codexSession = UUID(uuidString: "01A129CF-1A27-77A1-B68E-081C7700786A")!
private let codexTitle = "01a129cf-1a27-77a1-b68e-081c7..."
private let claudeSessionID = "d6a5e88b-35f1-4e9c-9bcd-da141952503f"
private let claudeTitle = "Herdly Claude d6a5e88b-35f1-4e9c-9bcd-da141952503f"
private let socketDirectory = "/var/folders/3m/abc/T/zellij-501/contract_version_1"

private func paneJSON(_ id: Int, plugin: Bool = false, title: String, tab: Int, floating: Bool = false,
                      selectable: Bool = true, exited: Bool = false, command: String? = nil) -> String {
    let commandField = plugin ? "" : ", \"pane_command\": \(command.map { "\"\($0)\"" } ?? "\"/bin/zsh\""), \"pane_cwd\": \"/Users/me\""
    return """
    {"id": \(id), "is_plugin": \(plugin), "is_focused": false, "is_fullscreen": false, "is_floating": \(floating),
     "is_suppressed": false, "title": "\(title)", "exited": \(exited), "exit_status": null, "is_held": false,
     "terminal_command": null, "plugin_url": \(plugin ? "\"tab-bar\"" : "null"), "is_selectable": \(selectable),
     "tab_id": \(tab), "tab_position": \(tab), "tab_name": "Tab #\(tab)"\(commandField)}
    """
}

private func tabJSON(_ id: Int, tiled: Int = 1, floating: Int = 0, floatingVisible: Bool = false) -> String {
    """
    {"position": \(id), "name": "Tab #\(id)", "active": false, "panes_to_hide": 0, "is_fullscreen_active": false,
     "is_sync_panes_active": false, "are_floating_panes_visible": \(floatingVisible), "other_focused_clients": [],
     "selectable_tiled_panes_count": \(tiled), "selectable_floating_panes_count": \(floating), "tab_id": \(id),
     "has_bell_notification": false, "is_flashing_bell": false}
    """
}

/// The proof's session: home tab 0, Codex 1, Claude 2, decoy 3, split 4 (terminal_4 and terminal_5),
/// plus the tab-bar plugin reusing id 0 and the suppressed `zellij:link` plugin.
private let labPanes = "[" + [
    paneJSON(0, plugin: true, title: "tab-bar", tab: 0, selectable: false),
    paneJSON(1, plugin: true, title: "(.) - zellij:link", tab: 0),
    paneJSON(0, title: "Pane #1", tab: 0),
    paneJSON(1, title: codexTitle, tab: 1, command: "~/.local/bin/codex -C /work -s read-only"),
    paneJSON(2, title: claudeTitle, tab: 2, command: "~/.local/bin/claude"),
    paneJSON(4, title: "Pane #1", tab: 4),
    paneJSON(5, title: "Pane #2", tab: 4),
].joined(separator: ",") + "]"
private let decoyPane = paneJSON(3, title: codexTitle, tab: 3, command: "sleep 3600")
private let labTabs = "[" + [tabJSON(0), tabJSON(1), tabJSON(2), tabJSON(4, tiled: 2)].joined(separator: ",") + "]"
private let labClients = "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n1 terminal_5 N/A\n"

// MARK: - Listing

@Test func zellijListingReadsPanesTabsAndClientsFromSavedOutput() throws {
    let session = try #require(ZellijSession.parse(name: "lab", panes: labPanes, tabs: labTabs, clients: labClients))
    #expect(session.panes.count == 7)
    #expect(session.panes[3] == ZellijPane(id: 1, isPlugin: false, title: codexTitle, tabID: 1, isFloating: false,
                                           isSelectable: true, exited: false, paneCommand: "~/.local/bin/codex -C /work -s read-only"))
    // A plugin reuses a terminal's number; it is never a terminal pane.
    #expect(session.terminalPane(0)?.title == "Pane #1")
    #expect(session.terminalPane(1)?.title == codexTitle)
    #expect(session.tabs.first { $0.tabID == 4 } == ZellijTab(tabID: 4, selectableTiledPanes: 2, selectableFloatingPanes: 0,
                                                               floatingPanesVisible: false))
    #expect(session.clients == [ZellijClient(clientID: "1", paneID: 5)])
}

@Test func zellijListingReadsVerbatimOutputFromAnIsolatedZellij() throws {
    // `list-panes --json --all`, `list-tabs --json` and `list-clients` from Zellij 0.45.1 on a private
    // socket directory with no client attached (paths shortened).
    let panes = """
    [{"id": 0, "is_plugin": true, "is_focused": false, "is_fullscreen": false, "is_floating": false, "is_suppressed": true,
      "title": "(.) - zellij:link", "exited": false, "exit_status": null, "is_held": false, "pane_x": 13, "pane_content_x": 14,
      "pane_y": 13, "pane_content_y": 14, "pane_rows": 24, "pane_content_rows": 22, "pane_columns": 25, "pane_content_columns": 23,
      "cursor_coordinates_in_pane": null, "terminal_command": null, "plugin_url": "zellij:link", "is_selectable": true,
      "index_in_pane_group": {}, "default_fg": null, "default_bg": null, "tab_id": 0, "tab_position": 0, "tab_name": "Tab #1"},
     {"id": 0, "is_plugin": false, "is_focused": true, "is_fullscreen": false, "is_floating": false, "is_suppressed": false,
      "title": "Pane #1", "exited": false, "exit_status": null, "is_held": false, "pane_x": 0, "pane_content_x": 0, "pane_y": 1,
      "pane_content_y": 1, "pane_rows": 48, "pane_content_rows": 48, "pane_columns": 50, "pane_content_columns": 50,
      "cursor_coordinates_in_pane": [8, 0], "terminal_command": null, "plugin_url": null, "is_selectable": true,
      "index_in_pane_group": {}, "default_fg": null, "default_bg": null, "tab_id": 0, "tab_position": 0, "tab_name": "Tab #1",
      "pane_command": "sleep 3001", "pane_cwd": "/private/tmp/z"}]
    """
    let tabs = """
    [{"position": 0, "name": "Tab #1", "active": false, "panes_to_hide": 0, "is_fullscreen_active": false,
      "is_sync_panes_active": false, "are_floating_panes_visible": false, "other_focused_clients": [],
      "active_swap_layout_name": null, "is_swap_layout_dirty": false, "viewport_rows": 48, "viewport_columns": 50,
      "display_area_rows": 50, "display_area_columns": 50, "selectable_tiled_panes_count": 1,
      "selectable_floating_panes_count": 0, "tab_id": 0, "has_bell_notification": false, "is_flashing_bell": false}]
    """
    let session = try #require(ZellijSession.parse(name: "lab", panes: panes, tabs: tabs, clients: "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n"))
    #expect(session.terminalPane(0) == ZellijPane(id: 0, isPlugin: false, title: "Pane #1", tabID: 0, isFloating: false,
                                                  isSelectable: true, exited: false, paneCommand: "sleep 3001"))
    #expect(session.tab(0)?.visiblePanes == 1)
    #expect(session.clients.isEmpty)
}

@Test func zellijListingReadsAClientShowingAPluginAndAClientWithACommand() throws {
    let clients = "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n1 terminal_3 sleep 3600\n2 plugin_0 N/A\n"
    let session = try #require(ZellijSession.parse(name: "lab", panes: labPanes, tabs: labTabs, clients: clients))
    #expect(session.clients == [ZellijClient(clientID: "1", paneID: 3), ZellijClient(clientID: "2", paneID: nil)])
    // No client attached: the header alone.
    let detached = try #require(ZellijSession.parse(name: "lab", panes: labPanes, tabs: labTabs,
                                                    clients: "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n"))
    #expect(detached.clients.isEmpty)
}

@Test func zellijListingRefusesMalformedOrOversizedOutput() {
    #expect(ZellijSession.parse(name: "lab", panes: "{}", tabs: labTabs, clients: labClients) == nil)
    #expect(ZellijSession.parse(name: "lab", panes: "[{\"id\": \"one\"}]", tabs: labTabs, clients: labClients) == nil)
    #expect(ZellijSession.parse(name: "lab", panes: "[" + paneJSON(-1, title: "x", tab: 0) + "]", tabs: labTabs, clients: labClients) == nil)
    #expect(ZellijSession.parse(name: "lab", panes: labPanes, tabs: "[{\"tab_id\": 0}]", clients: labClients) == nil)
    #expect(ZellijSession.parse(name: "lab", panes: labPanes, tabs: labTabs, clients: "1 terminal_5 N/A\n") == nil)
    #expect(ZellijSession.parse(name: "lab", panes: labPanes, tabs: labTabs,
                                clients: "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\nx terminal_5 N/A\n") == nil)
    #expect(ZellijSession.parse(name: "lab", panes: labPanes, tabs: labTabs,
                                clients: "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n1 pane_5 N/A\n") == nil)
    let huge = "[" + String(repeating: " ", count: ZellijListing.maximumOutput) + "]"
    #expect(ZellijSession.parse(name: "lab", panes: huge, tabs: labTabs, clients: labClients) == nil)
    let long = "[" + paneJSON(0, title: String(repeating: "t", count: ZellijSession.maximumTitleLength + 1), tab: 0) + "]"
    #expect(ZellijSession.parse(name: "lab", panes: long, tabs: labTabs, clients: labClients) == nil)
}

@Test func zellijVersionNeedsZeroFortyFourOneOrLater() {
    #expect(ZellijVersion.parse("zellij 0.45.1\n") == ZellijVersion(major: 0, minor: 45, patch: 1))
    #expect(ZellijVersion.parse("zellij 0.45.1")?.isSupported == true)
    #expect(ZellijVersion.parse("zellij 0.44.1")?.isSupported == true)
    #expect(ZellijVersion.parse("zellij 0.44.0")?.isSupported == false)
    #expect(ZellijVersion.parse("zellij 0.43.1")?.isSupported == false)
    #expect(ZellijVersion.parse("zellij 1.0.0")?.isSupported == true)
    #expect(ZellijVersion.parse("tmux 3.5") == nil)
    #expect(ZellijVersion.parse("zellij x.y") == nil)
}

@Test func zellijDefaultSocketDirectoryIsTheContractDirectoryUnderTheUserTemporaryDirectory() {
    #expect(ZellijSocketDirectory.path(temporaryDirectory: "/var/folders/3m/abc/T/", uid: 501) == socketDirectory)
    #expect(ZellijSocketDirectory.path(temporaryDirectory: "/var/folders/3m/abc/T", uid: 501) == socketDirectory)
    #expect(ZellijSocketDirectory.path(temporaryDirectory: "", uid: 501) == nil)
    #expect(ZellijSocketDirectory.path(temporaryDirectory: "relative/T", uid: 501) == nil)
}

@Test func zellijSocketTrustNeedsOwnerOnlyDirectoriesAndSocketsOfThisUser() {
    let base = TmuxFileFacts(kind: .directory, owner: 501, mode: 0o700)
    let directory = TmuxFileFacts(kind: .directory, owner: 501, mode: 0o700)
    let socket = TmuxFileFacts(kind: .socket, owner: 501, mode: 0o1700)
    #expect(ZellijSocketTrust.problem(base: base, directory: nil, sockets: [:], me: 501) == .notRunning)
    #expect(ZellijSocketTrust.problem(base: base, directory: directory, sockets: [:], me: 501) == .notRunning)
    #expect(ZellijSocketTrust.problem(base: base, directory: directory, sockets: ["lab": socket], me: 501) == nil)
    #expect(ZellijSocketTrust.problem(base: base, directory: TmuxFileFacts(kind: .directory, owner: 501, mode: 0o755),
                                      sockets: ["lab": socket], me: 501) == .untrusted)
    #expect(ZellijSocketTrust.problem(base: TmuxFileFacts(kind: .directory, owner: 0, mode: 0o700), directory: directory,
                                      sockets: ["lab": socket], me: 501) == .untrusted)
    #expect(ZellijSocketTrust.problem(base: base, directory: TmuxFileFacts(kind: .other, owner: 501, mode: 0o700),
                                      sockets: ["lab": socket], me: 501) == .untrusted)
    #expect(ZellijSocketTrust.problem(base: base, directory: directory,
                                      sockets: ["lab": TmuxFileFacts(kind: .socket, owner: 502, mode: 0o1700)], me: 501) == .untrusted)
    #expect(ZellijSocketTrust.problem(base: base, directory: directory,
                                      sockets: ["lab": TmuxFileFacts(kind: .socket, owner: 501, mode: 0o1777)], me: 501) == .untrusted)
}

@Test func zellijSessionNamesAreAddressedOnlyWhenTheyCannotBeReadAsAnOption() {
    #expect(ZellijSessionName.validated("lab") == "lab")
    #expect(ZellijSessionName.validated("fearless-sloth") == "fearless-sloth")
    #expect(ZellijSessionName.validated("my project") == "my project")
    #expect(ZellijSessionName.validated("-x") == nil)
    #expect(ZellijSessionName.validated("") == nil)
    #expect(ZellijSessionName.validated("a\nb") == nil)
    #expect(ZellijSessionName.validated(String(repeating: "a", count: 256)) == nil)
}

@Test func zellijBinaryResolvesOnlyFromFixedLocations() {
    #expect(ZellijBinary.resolve(isExecutable: { $0 == "/usr/local/bin/zellij" }) == "/usr/local/bin/zellij")
    #expect(ZellijBinary.resolve(isExecutable: { _ in true }) == "/opt/homebrew/bin/zellij")
    #expect(ZellijBinary.resolve(isExecutable: { $0 == "/Users/me/.cargo/bin/zellij" }) == nil)
}

// MARK: - Processes

/// The proof's process tree: the server (daemonized, no tty), Codex and Claude under it, the one
/// client in the WezTerm tab on /dev/ttys017, and a Claude process in an unrelated terminal tab.
private let psOutput = """
    1     0 ??       /sbin/launchd
  900     1 ??       /Applications/WezTerm.app/Contents/MacOS/wezterm-gui
  901   900 ttys017  -zsh
49075   901 ttys017  /opt/homebrew/bin/zellij
49121     1 ??       /opt/homebrew/bin/zellij
49200 49121 ttys019  /bin/zsh
49201 49200 ttys019  /Users/me/.local/bin/codex
49300 49121 ttys020  /bin/zsh
49301 49300 ttys020  /Users/me/.local/bin/claude
  950   900 ttys030  -zsh
  951   950 ttys030  /Users/me/.local/bin/claude

"""
private let serverArguments: [Int32: [String]] = [
    49075: ["zellij", "--session", "lab"],
    49121: ["/opt/homebrew/bin/zellij", "--server", socketDirectory + "/lab"],
]
private let serverStart: [Int32: Double] = [49121: 1_791_702_790]

/// `ps -axo pid=,ppid=,uid=,tty=,comm=`: the fixtures above, each row given `uid` 501 unless it already
/// names one after a `uid:` marker (another user's process).
private func withUIDs(_ output: String) -> String {
    output.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3 else { return String(line) }
        if fields[2].hasPrefix("uid:") {
            let rest = fields[2].dropFirst(4).split(separator: " ", maxSplits: 1)
            return "\(fields[0]) \(fields[1]) \(rest[0]) \(rest[1])"
        }
        return "\(fields[0]) \(fields[1]) 501 \(fields[2])"
    }.joined(separator: "\n")
}

private func processTable(_ output: String = psOutput, arguments: [Int32: [String]] = serverArguments,
                          startTimes: [Int32: Double] = serverStart) -> ZellijProcessTable? {
    ZellijProcessTable.parse(withUIDs(output), owner: 501, arguments: arguments, startTimes: startTimes)
}

@Test func zellijProcessTableFindsEachSessionsServerAndTheClientProcesses() throws {
    let table = try #require(processTable())
    #expect(table.server(session: "lab", socketDirectory: socketDirectory) == ZellijServerIdentity(pid: 49121, startedAt: 1_791_702_790))
    #expect(table.server(session: "other", socketDirectory: socketDirectory) == nil)
    // A server on a custom ZELLIJ_SOCKET_DIR is never the default directory's.
    #expect(table.server(session: "lab", socketDirectory: "/tmp/custom/contract_version_1") == nil)
    #expect(table.clientProcesses.map(\.pid) == [49075])
    #expect(table.clientProcesses.first?.tty == "/dev/ttys017")
    #expect(table.descends(49201, from: 49121))
    #expect(!table.descends(951, from: 49121))
    #expect(table.processes(named: "codex", under: 49121).map(\.pid) == [49201])
}

@Test func zellijClientProcessesAreCountedForThisUserOnly() throws {
    // Another user's `zellij` client is never this user's (ADR 0014, "for the user"); it is still in the
    // table, so ancestry through it reads.
    let table = try #require(processTable(psOutput + "52000   950 uid:502 ttys040  /opt/homebrew/bin/zellij\n"))
    #expect(table.clientProcesses.map(\.pid) == [49075])
    #expect(table.processes[52000]?.uid == 502)
}

@Test func zellijProcessTableRefusesMalformedOutput() {
    #expect(processTable("x 1 ?? /bin/zsh\n") == nil)
    #expect(processTable("10 1\n") == nil)
    #expect(ZellijProcessTable.parse("10 1 x ?? zsh\n", owner: 501, arguments: [:], startTimes: [:]) == nil)
    #expect(processTable(String(repeating: "10 1 ?? zsh\n", count: ZellijProcessTable.maximumProcesses + 1)) == nil)
}

@Test func zellijServerWithoutAStartTimeOrWithTwoServersIsNotFound() throws {
    #expect(try #require(processTable(startTimes: [:])).server(session: "lab", socketDirectory: socketDirectory) == nil)
    let twice = psOutput + "49122     1 ??       /opt/homebrew/bin/zellij\n"
    var arguments = serverArguments
    arguments[49122] = ["zellij", "--server", socketDirectory + "/lab"]
    let table = try #require(processTable(twice, arguments: arguments, startTimes: [49121: 1, 49122: 2]))
    #expect(table.server(session: "lab", socketDirectory: socketDirectory) == nil)
}

// MARK: - Snapshot and inventory

private func labSession(panes: String = labPanes, tabs: String = labTabs, clients: String = labClients) -> ZellijSession? {
    ZellijSession.parse(name: "lab", panes: panes, tabs: tabs, clients: clients)
}

private func zellijSnapshot(_ sessions: [ZellijSession?]? = nil, table: ZellijProcessTable? = nil) -> ZellijSnapshot? {
    let sessions = sessions ?? [labSession()]
    guard let table = table ?? processTable(), sessions.allSatisfy({ $0 != nil }) else { return nil }
    return ZellijSnapshot(socketDirectory: socketDirectory, sessions: sessions.compactMap { $0 }, processes: table)
}

@Test func zellijInventoryListsEachTerminalPaneWithoutATtyAndItsTabsVisiblePanes() throws {
    let snapshot = try #require(zellijSnapshot())
    #expect(snapshot.inventory == .tabs([
        TerminalTab(tabID: "lab/terminal_0", tty: nil, title: "Pane #1", paneCount: 1),
        TerminalTab(tabID: "lab/terminal_1", tty: nil, title: codexTitle, paneCount: 1),
        TerminalTab(tabID: "lab/terminal_2", tty: nil, title: claudeTitle, paneCount: 1),
        TerminalTab(tabID: "lab/terminal_4", tty: nil, title: "Pane #1", paneCount: 2),
        TerminalTab(tabID: "lab/terminal_5", tty: nil, title: "Pane #2", paneCount: 2),
    ]))
    // The client's host tab is left out of the Codex title count, as tmux's is (ADR 0014).
    #expect(snapshot.clientTTYs == ["/dev/ttys017"])
    #expect(ZellijPaneTarget(handle: "lab/terminal_1") == ZellijPaneTarget(session: "lab", paneID: 1))
    #expect(ZellijPaneTarget(handle: "my/odd/terminal_1") == nil)
    #expect(ZellijPaneTarget(handle: "lab/plugin_1") == nil)
}

@Test func zellijReadsInventoryFollowsADR0013() throws {
    #expect(ZellijRead.notRunning.inventory == .notRunning)
    #expect(ZellijRead.binaryNotFound.inventory == .unreadable)
    #expect(ZellijRead.untrustedSocket.inventory == .unreadable)
    #expect(ZellijRead.unreadable(.staleSocket).inventory == .unreadable)
    // An old Zellij keeps its sessions out of reach while one runs, and holds nothing while none does.
    #expect(ZellijRead.unsupportedVersion(ZellijVersion(major: 0, minor: 43, patch: 1), running: true).inventory == .unreadable)
    #expect(ZellijRead.unsupportedVersion(ZellijVersion(major: 0, minor: 43, patch: 1), running: false).inventory == .notRunning)
    let snapshot = try #require(zellijSnapshot())
    #expect(ZellijRead.snapshot(snapshot).inventory == snapshot.inventory)
}

// MARK: - Codex binding (ADR 0014)

private let zellijSwitches = TerminalHostSwitches(enabled: [.wezTerm, .zellij])
private let hostTTY = "/dev/ttys017"

/// WezTerm holding the client's tab, titled as Zellij titles its host (`<session> | <pane title>`).
private func wezTermTabs(clientTitle: String = "lab | \(codexTitle)", extra: [TerminalTab] = []) -> TerminalHostInventory {
    .tabs([TerminalTab(tabID: "8", tty: hostTTY, title: clientTitle, paneCount: 1),
           TerminalTab(tabID: "12", tty: "/dev/ttys030", title: "zsh", paneCount: 1)] + extra)
}

private func zellijCodexBinding(_ snapshot: ZellijSnapshot?, second: ZellijSnapshot?? = nil,
                                wezTerm: TerminalHostInventory? = nil, secondWezTerm: TerminalHostInventory? = nil,
                                processes: [String: [TerminalProcess]] = [:],
                                switches: TerminalHostSwitches = zellijSwitches) -> ZellijBinding {
    var inventories: [TerminalHost: TerminalHostInventory] = [.wezTerm: wezTerm ?? wezTermTabs()]
    if switches.isOn(.zellij) { inventories[.zellij] = snapshot.map(\.inventory) ?? .unreadable }
    var secondRead = inventories
    if let second { secondRead[.zellij] = second.map(\.inventory) ?? .unreadable }
    if let secondWezTerm { secondRead[.wezTerm] = secondWezTerm }
    return ZellijBindingRules.codex(sessionID: codexSession.uuidString, liveness: .live,
                                    liveSessions: [codexSession.uuidString], switches: switches,
                                    inventories: inventories, processes: processes, secondRead: secondRead,
                                    multiplexerClientTTYs: snapshot?.clientTTYs ?? [], zellij: snapshot)
}

@Test func zellijCodexPaneBindsByTitlePaneCommandAndACodexUnderTheServer() throws {
    let snapshot = try #require(zellijSnapshot())
    #expect(zellijCodexBinding(snapshot) == .bound(ZellijPaneTarget(session: "lab", paneID: 1)))
}

@Test func zellijDecoyPaneCarryingTheTitleLeavesTheSessionUnbound() throws {
    let panes = String(labPanes.dropLast()) + "," + decoyPane + "]"
    let tabs = String(labTabs.dropLast()) + "," + tabJSON(3) + "]"
    let snapshot = try #require(zellijSnapshot([labSession(panes: panes, tabs: tabs)]))
    #expect(zellijCodexBinding(snapshot) == .unavailable(.terminal(.duplicateTitles(2))))
    // A tab of another enabled host carrying the title is a second candidate too.
    let titled = TerminalTab(tabID: "14", tty: "/dev/ttys031", title: codexTitle, paneCount: 1)
    #expect(zellijCodexBinding(try #require(zellijSnapshot()), wezTerm: wezTermTabs(extra: [titled]))
            == .unavailable(.terminal(.duplicateTitles(2))))
}

@Test func aTerminalTabDecoyBesideAZellijCodexPaneLeavesThePaneBound() throws {
    // #268: a WezTerm tab prints the title over `sleep`. Its `ps` shows no `codex`, so it is no candidate
    // on either read. A Zellij pane lists no tty and keeps counting by title (ADR 0014), as tested above.
    let titled = TerminalTab(tabID: "14", tty: "/dev/ttys031", title: codexTitle, paneCount: 1)
    let sleeping = ["/dev/ttys031": [TerminalProcess(pid: 77, name: "sleep", foreground: true)]]
    #expect(zellijCodexBinding(try #require(zellijSnapshot()), wezTerm: wezTermTabs(extra: [titled]), processes: sleeping)
            == .bound(ZellijPaneTarget(session: "lab", paneID: 1)))
    // A decoy that appears only in the second read had no `ps` read: the binding is void.
    #expect(zellijCodexBinding(try #require(zellijSnapshot()), secondWezTerm: wezTermTabs(extra: [titled]))
            == .unavailable(.titleChanged))
}

@Test func zellijDecoyAloneNeedsCodexAsItsPaneCommandAndUnderTheServer() throws {
    // The decoy prints Codex's title over `sleep`: its pane command is not Codex.
    let decoyOnly = "[" + paneJSON(3, title: codexTitle, tab: 3, command: "sleep 3600") + "]"
    let decoy = try #require(zellijSnapshot([labSession(panes: decoyOnly, tabs: "[" + tabJSON(3) + "]")]))
    #expect(zellijCodexBinding(decoy) == .unavailable(.notCodexCommand))
    // A pane command naming Codex with no `codex` process under the session's server.
    let noCodex = psOutput.replacingOccurrences(of: "/Users/me/.local/bin/codex", with: "/bin/sleep")
    let missing = try #require(zellijSnapshot(table: processTable(noCodex)))
    #expect(zellijCodexBinding(missing) == .unavailable(.codexNotUnderServer))
    // No server process for the session in the default directory (a renamed session, or a custom one).
    let elsewhere = try #require(zellijSnapshot(table: processTable(arguments: [49121: ["zellij", "--server", "/tmp/x/lab"]])))
    #expect(zellijCodexBinding(elsewhere) == .unavailable(.serverNotFound))
}

@Test func zellijCodexBindingNeedsASecondReadShowingTheSamePane() throws {
    let snapshot = try #require(zellijSnapshot())
    let renamed = labPanes.replacingOccurrences(of: codexTitle, with: "Pane #9")
    let second = try #require(zellijSnapshot([labSession(panes: renamed)]))
    #expect(zellijCodexBinding(snapshot, second: second) == .unavailable(.titleChanged))
    #expect(zellijCodexBinding(snapshot, second: .some(nil)) == .unavailable(.terminal(.hostUnreadable(.zellij))))
}

@Test func zellijCodexPaneInASplitTabIsUnavailable() throws {
    let tabs = labTabs.replacingOccurrences(of: tabJSON(1), with: tabJSON(1, tiled: 1, floating: 1, floatingVisible: true))
    let snapshot = try #require(zellijSnapshot([labSession(tabs: tabs)]))
    #expect(zellijCodexBinding(snapshot) == .unavailable(.split))
    // A hidden floating pane leaves the tab's one visible pane.
    let hidden = labTabs.replacingOccurrences(of: tabJSON(1), with: tabJSON(1, tiled: 1, floating: 1, floatingVisible: false))
    #expect(zellijCodexBinding(try #require(zellijSnapshot([labSession(tabs: hidden)])))
            == .bound(ZellijPaneTarget(session: "lab", paneID: 1)))
}

@Test func zellijIsNotAskedAboutASessionNoPaneCarriesOrABindingElsewhere() throws {
    // The title in a WezTerm tab only: the WezTerm rules decide; Zellij has nothing to say.
    let others = "[" + paneJSON(0, title: "Pane #1", tab: 0) + "]"
    let snapshot = try #require(zellijSnapshot([labSession(panes: others, tabs: "[" + tabJSON(0) + "]")]))
    let titled = TerminalTab(tabID: "14", tty: "/dev/ttys031", title: codexTitle, paneCount: 1)
    #expect(zellijCodexBinding(snapshot, wezTerm: wezTermTabs(extra: [titled])) == .notInZellij)
    // Zellij switched off: never read, never asked.
    #expect(zellijCodexBinding(nil, switches: TerminalHostSwitches(enabled: [.wezTerm])) == .notInZellij)
}

@Test func anUnreadableZellijLeavesEverySessionItCouldHoldUnavailable() throws {
    // A Codex session bound in WezTerm cannot be told apart from one in an unread Zellij (ADR 0013).
    let titled = TerminalTab(tabID: "14", tty: "/dev/ttys031", title: codexTitle, paneCount: 1)
    let inventories: [TerminalHost: TerminalHostInventory] = [.wezTerm: wezTermTabs(extra: [titled]), .zellij: .unreadable]
    let processes = ["/dev/ttys031": [TerminalProcess(pid: 7, name: "codex", foreground: true)]]
    #expect(TerminalTabBindingRules.codex(sessionID: codexSession.uuidString, liveness: .live,
                                          liveSessions: [codexSession.uuidString], switches: zellijSwitches,
                                          inventories: inventories, processes: processes, secondRead: inventories)
            == .unavailable(.hostUnreadable(.zellij)))
    // And Ghostty's question key fails closed until Zellij is read fresh (cross-host freshness).
    let ghostty = TerminalHostSwitches(enabled: [.ghostty, .zellij])
    #expect(TerminalKeyRelayCheck.hostsToRead(switches: ghostty) == [.zellij])
    #expect(TerminalKeyRelayCheck.ghosttyVeto(title: codexTitle, processes: [:], switches: ghostty,
                                              fresh: [.zellij: try #require(zellijSnapshot()).inventory])
            == .noQuestionKeys(.zellij))
}

// MARK: - Claude binding (ADR 0014: hook pane id and ancestry)

private let claudeProcess = TerminalSessionProcess.registered(ClaudeSessionRegistry.Process(pid: 49301, procStart: "Mon Oct 12 09:00:00 2026"))
private let claudeObserved = TerminalProcessObservation(pid: 49301, procStart: "Mon Oct 12 09:00:00 2026", tty: "/dev/ttys020")
private let claudeHookPane = ZellijHookPane(paneID: "2", sessionName: "lab")

private func hookRecord(pane: ZellijHookPane?, at time: Double = 100) -> HerdrHookPaneRecord {
    HerdrHookPaneRecord(sessionID: claudeSessionID, agent: .claude, paneID: nil, socketPath: nil, recordedAt: time,
                        zellijPane: pane)
}

private func zellijClaudeBinding(_ read: ZellijRead?, records: [HerdrHookPaneRecord] = [hookRecord(pane: claudeHookPane)],
                                 process: TerminalSessionProcess = claudeProcess,
                                 observed: TerminalProcessObservation? = claudeObserved) -> ZellijBinding {
    ZellijBindingRules.claude(sessionID: claudeSessionID, liveness: .live, newestRecords: records, process: process,
                              observed: observed, zellij: read)
}

@Test func zellijHookPaneIsReadIntoTheNewestHookRecordsOfClaudeOnly() throws {
    func object(_ source: String, session: String) -> [String: Any] {
        var record: [String: Any] = ["hook_event_name": "SessionStart", "session_id": session, "source": source,
                                     "captured_at": 1_791_702_801.288976]
        TerminalHookIdentifiers.record(from: ["ZELLIJ_PANE_ID": "2", "ZELLIJ_SESSION_NAME": "lab"], into: &record)
        return record
    }
    let claude = try #require(HerdrBindingInputs.hookRecord(from: object(ClaudeSetupRequirements.helperSource, session: claudeSessionID)))
    #expect(claude.zellijPane == claudeHookPane)
    // A Codex record's Zellij variables are the shared daemon's, never a binding input (ADR 0012).
    let codex = try #require(HerdrBindingInputs.hookRecord(from: object(CodexSetupRequirements.helperSource,
                                                                       session: codexSession.uuidString)))
    #expect(codex.zellijPane == nil)
    // Two newest records naming different panes reach the rule as a conflict.
    let other = HerdrHookPaneRecord(sessionID: claudeSessionID, agent: .claude, paneID: nil, socketPath: nil,
                                    recordedAt: claude.recordedAt, zellijPane: ZellijHookPane(paneID: "1", sessionName: "lab"))
    #expect(HerdrBindingInputs.newestRecords([claude, other]).count == 2)
    #expect(HerdrBindingInputs.newestRecords([claude, claude]) == [claude])
}

@Test func zellijClaudePaneBindsWhenTheHookPaneAndTheProcessAncestryAgree() throws {
    let read = ZellijRead.snapshot(try #require(zellijSnapshot()))
    #expect(zellijClaudeBinding(read) == .bound(ZellijPaneTarget(session: "lab", paneID: 2)))
    // A user-named pane loses Herdly's title; the title is not required.
    let named = labPanes.replacingOccurrences(of: claudeTitle, with: "my work")
    #expect(zellijClaudeBinding(.snapshot(try #require(zellijSnapshot([labSession(panes: named)]))))
            == .bound(ZellijPaneTarget(session: "lab", paneID: 2)))
}

@Test func zellijClaudeBindingIsNotZellijsWithoutAHookPaneOrWithoutAZellijAncestor() throws {
    let read = ZellijRead.snapshot(try #require(zellijSnapshot()))
    #expect(zellijClaudeBinding(read, records: []) == .notInZellij)
    #expect(zellijClaudeBinding(read, records: [hookRecord(pane: nil)]) == .notInZellij)
    // An inherited ZELLIJ_PANE_ID in a process no Zellij server is above: the terminal rules decide.
    let outside = TerminalSessionProcess.registered(ClaudeSessionRegistry.Process(pid: 951, procStart: "t"))
    #expect(zellijClaudeBinding(read, process: outside, observed: TerminalProcessObservation(pid: 951, procStart: "t", tty: "/dev/ttys030"))
            == .notInZellij)
    #expect(zellijClaudeBinding(.notRunning) == .notInZellij)
}

@Test func zellijClaudeBindingFailsClosedOnEveryDisagreement() throws {
    let read = ZellijRead.snapshot(try #require(zellijSnapshot()))
    // Newest records disagree.
    #expect(zellijClaudeBinding(read, records: [hookRecord(pane: claudeHookPane),
                                                hookRecord(pane: ZellijHookPane(paneID: "1", sessionName: "lab"))])
            == .unavailable(.conflictingHookRecords))
    // The recorded pane is not a terminal pane of that session.
    #expect(zellijClaudeBinding(read, records: [hookRecord(pane: ZellijHookPane(paneID: "9", sessionName: "lab"))])
            == .unavailable(.hookPaneMissing))
    // Recorded in another session than the one whose server the process runs under.
    #expect(zellijClaudeBinding(read, records: [hookRecord(pane: ZellijHookPane(paneID: "2", sessionName: "other"))])
            == .unavailable(.processNotUnderServer))
    // The pane's title names a different session.
    let other = labPanes.replacingOccurrences(of: claudeTitle, with: "Herdly Claude 00000000-0000-0000-0000-000000000000")
    #expect(zellijClaudeBinding(.snapshot(try #require(zellijSnapshot([labSession(panes: other)])))) == .unavailable(.conflictingTitle))
    // The pane shares its tab.
    let split = labTabs.replacingOccurrences(of: tabJSON(2), with: tabJSON(2, tiled: 2))
    #expect(zellijClaudeBinding(.snapshot(try #require(zellijSnapshot([labSession(tabs: split)])))) == .unavailable(.split))
    // The registered process is gone or its PID was reused.
    #expect(zellijClaudeBinding(read, observed: nil) == .unavailable(.terminal(.processEnded)))
    #expect(zellijClaudeBinding(read, observed: TerminalProcessObservation(pid: 49301, procStart: "later", tty: nil))
            == .unavailable(.terminal(.processStartMismatch)))
    #expect(zellijClaudeBinding(read, process: .ambiguous) == .unavailable(.terminal(.processAmbiguous)))
    // An unreadable Zellij could hold the session.
    #expect(zellijClaudeBinding(.unreadable(.commandFailed)) == .unavailable(.terminal(.hostUnreadable(.zellij))))
    #expect(zellijClaudeBinding(nil) == .unavailable(.terminal(.hostUnreadable(.zellij))))
}

// MARK: - Layout, clients and nesting (ADR 0014)

private let codexPane = ZellijPaneTarget(session: "lab", paneID: 1)
private let server = ZellijServerIdentity(pid: 49121, startedAt: 1_791_702_790)
private let openClient = ZellijOpenClient(clientID: "1", pid: 49075, tty: hostTTY)

@Test func zellijPaneLayerNeedsALivePaneAloneInItsTabAndNoNesting() throws {
    let snapshot = try #require(zellijSnapshot())
    #expect(ZellijLayout.paneLayer(codexPane, in: snapshot) == nil)
    #expect(ZellijLayout.paneLayer(ZellijPaneTarget(session: "lab", paneID: 9), in: snapshot) == .paneGone)
    #expect(ZellijLayout.paneLayer(ZellijPaneTarget(session: "gone", paneID: 1), in: snapshot) == .paneGone)
    #expect(ZellijLayout.paneLayer(ZellijPaneTarget(session: "lab", paneID: 4), in: snapshot) == .split)
    let exited = labPanes.replacingOccurrences(of: paneJSON(1, title: codexTitle, tab: 1, command: "~/.local/bin/codex -C /work -s read-only"),
                                               with: paneJSON(1, title: codexTitle, tab: 1, exited: true, command: "~/.local/bin/codex"))
    #expect(ZellijLayout.paneLayer(codexPane, in: try #require(zellijSnapshot([labSession(panes: exited)]))) == .paneExited)
    let noServer = try #require(zellijSnapshot(table: processTable(arguments: [:])))
    #expect(ZellijLayout.paneLayer(codexPane, in: noServer) == .serverNotFound)
}

@Test func zellijClientRunningInsideAnotherMultiplexersPaneIsNested() throws {
    // The client's shell runs in a tmux pane: Zellij inside tmux (ADR 0014, "Nesting").
    let inTmux = psOutput.replacingOccurrences(of: "  901   900 ttys017  -zsh", with: "  901   880 ttys017  -zsh\n  880     1 ??       /opt/homebrew/bin/tmux")
    #expect(ZellijLayout.paneLayer(codexPane, in: try #require(zellijSnapshot(table: processTable(inTmux)))) == .nested)
    // Inside herdr, or another Zellij's pane, likewise.
    let inHerdr = psOutput.replacingOccurrences(of: "  901   900 ttys017  -zsh", with: "  901   880 ttys017  -zsh\n  880     1 ??       /opt/homebrew/bin/herdr")
    #expect(ZellijLayout.paneLayer(codexPane, in: try #require(zellijSnapshot(table: processTable(inHerdr)))) == .nested)
    // An ancestry that cannot be read cannot rule nesting out.
    let broken = psOutput.replacingOccurrences(of: "  901   900 ttys017  -zsh\n", with: "")
    #expect(ZellijLayout.paneLayer(codexPane, in: try #require(zellijSnapshot(table: processTable(broken)))) == .nested)
    // And tmux's own check already treats a `zellij` above a tmux client as nested.
    #expect(TmuxLayout.nestingCommands.contains("zellij"))
}

@Test func zellijOpenNeedsOneClientOnTheSessionAndOneZellijClientProcess() throws {
    let snapshot = try #require(zellijSnapshot())
    #expect(ZellijLayout.client(for: codexPane, in: snapshot) == .success(openClient))
    let none = try #require(zellijSnapshot([labSession(clients: ZellijListing.clientsHeader + "\n")]))
    #expect(ZellijLayout.client(for: codexPane, in: none) == .failure(.noClient))
    let two = try #require(zellijSnapshot([labSession(clients: labClients + "2 terminal_1 N/A\n")]))
    #expect(ZellijLayout.client(for: codexPane, in: two) == .failure(.clients(2)))
    // A second `zellij` client process anywhere: no client can be tied to this session (ADR 0014).
    let second = psOutput + "49615   950 ttys024  /opt/homebrew/bin/zellij\n"
    #expect(ZellijLayout.client(for: codexPane, in: try #require(zellijSnapshot(table: processTable(second))))
            == .failure(.clientProcesses(2)))
}

// MARK: - Two-layer Open (ADR 0014 "Open sequence", ADR 0015, ADR 0016)

private let hostTab = TerminalTabTarget(host: .wezTerm, tabID: "8", tty: hostTTY)
private let openPlan = ZellijOpenPlan(pane: codexPane, client: openClient, server: server, host: .tab(hostTab))

@Test func zellijOpenPlanJoinsTheClientTTYToOneHostTabTitledForTheSession() throws {
    let snapshot = try #require(zellijSnapshot())
    func plan(_ title: String?, join: MultiplexerHostJoin = .tab(hostTab)) -> Result<ZellijOpenPlan, OpenMiss> {
        ZellijOpen.plan(.bound(codexPane), snapshot: snapshot, join: { _ in join }, hostTitle: { _ in title })
    }
    #expect(plan("lab | \(codexTitle)") == .success(openPlan))
    #expect(plan("lab | Pane #1") == .success(openPlan))
    // The `<session> | ` host title is a veto: another title, or none, is no exact host tab.
    #expect(plan("zsh") == .failure(.fallBack(.noUniqueTarget, candidates: 1)))
    #expect(plan("other | \(codexTitle)") == .failure(.fallBack(.noUniqueTarget, candidates: 1)))
    #expect(plan("lab") == .failure(.fallBack(.noUniqueTarget, candidates: 1)))
    #expect(plan(nil) == .failure(.fallBack(.noUniqueTarget, candidates: 1)))
    // Ghostty's own join decides at raise time, where the title is checked (`hostTitleAllowed`).
    #expect(plan(nil, join: .ghostty) == .success(ZellijOpenPlan(pane: codexPane, client: openClient, server: server, host: .ghostty)))
    #expect(ZellijOpen.hostTitleAllowed("lab | \(codexTitle)", for: openPlan))
    #expect(!ZellijOpen.hostTitleAllowed("zellij", for: openPlan))
    // Ghostty's matched terminal's title is what the veto reads there.
    let ghosttyJSON = #"{"status":"ok","windows":[{"id":"w1","tabs":[{"id":"t1","terminals":[{"id":"s1","name":"lab | Pane #1"}]}]}],"front_window_id":"w1","selected":null}"#
    let ghostty = try JSONDecoder().decode(GhosttySnapshot.self, from: Data(ghosttyJSON.utf8))
    #expect(ghostty.terminalName(GhosttyTarget(window_id: "w1", tab_id: "t1", terminal_id: "s1")) == "lab | Pane #1")
    #expect(ghostty.terminalName(GhosttyTarget(window_id: "w1", tab_id: "t1", terminal_id: "s9")) == nil)
    // A join that misses keeps its own outcome; the pane is never focused.
    #expect(plan("lab | x", join: .miss(.unavailable(.hostUnreadable(.iTerm2)))) == .failure(.unavailable(.hostUnreadable(.iTerm2))))
}

@Test func zellijOpenPlanMapsBindingLayoutAndClientFailuresByADR0015() throws {
    let snapshot = try #require(zellijSnapshot())
    func plan(_ binding: ZellijBinding, _ snapshot: ZellijSnapshot) -> Result<ZellijOpenPlan, OpenMiss> {
        ZellijOpen.plan(binding, snapshot: snapshot, join: { _ in .tab(hostTab) }, hostTitle: { _ in "lab | x" })
    }
    #expect(plan(.unavailable(.terminal(.hostUnreadable(.zellij))), snapshot) == .failure(.unavailable(.hostUnreadable(.zellij))))
    #expect(plan(.unavailable(.terminal(.processEnded)), snapshot) == .failure(.unavailable(.sessionEnded)))
    #expect(plan(.unavailable(.terminal(.duplicateTitles(2))), snapshot) == .failure(.fallBack(.noUniqueTarget, candidates: 2)))
    #expect(plan(.unavailable(.split), snapshot) == .failure(.fallBack(.unsupportedLayout, candidates: 1)))
    #expect(plan(.unavailable(.notCodexCommand), snapshot) == .failure(.fallBack(.noUniqueTarget, candidates: 1)))
    #expect(plan(.notInZellij, snapshot) == .failure(.fallBack(.noUniqueTarget, candidates: 1)))
    // A second client process or a second client: an unsupported layout; the fallback walks every client.
    let second = try #require(zellijSnapshot(table: processTable(psOutput + "49615   950 ttys024  /opt/homebrew/bin/zellij\n")))
    #expect(plan(.bound(codexPane), second) == .failure(.fallBack(.unsupportedLayout, candidates: 1)))
    #expect(ZellijOpen.fallbackClientPIDs(in: second) == [49075, 49615])
    #expect(ZellijOpen.fallbackClientPIDs(in: nil) == [])
    let nested = psOutput.replacingOccurrences(of: "  901   900 ttys017  -zsh", with: "  901   880 ttys017  -zsh\n  880     1 ??       /opt/homebrew/bin/tmux")
    #expect(plan(.bound(codexPane), try #require(zellijSnapshot(table: processTable(nested))))
            == .failure(.fallBack(.unsupportedLayout, candidates: 1)))
}

@Test func zellijOpenFocusesThePaneOnceAndVerifiesItThroughListClients() throws {
    #expect(ZellijOpen.focusArguments(openPlan) == ["--session", "lab", "action", "focus-pane-id", "terminal_1"])
    #expect(ZellijOpen.focused(.succeeded("")) == nil)
    // "already focused" exits 2; only the verification can say it succeeded (ADR 0014 step 3).
    #expect(ZellijOpen.focused(.failed(stderr: "Pane Terminal(1) is already focused")) == nil)
    #expect(ZellijOpen.focused(.failed(stderr: "Pane with id Terminal(99) not found")) == .fallBack(.notVerified, candidates: 1))
    #expect(ZellijOpen.focused(.timedOut) == .fallBack(.notVerified, candidates: 1))
    #expect(ZellijOpen.focused(.notLaunched) == .unavailable(.hostUnreadable(.zellij)))

    let moved = try #require(zellijSnapshot([labSession(clients: ZellijListing.clientsHeader + "\n1 terminal_1 ~/.local/bin/codex\n")]))
    #expect(ZellijOpen.verifyPane(openPlan, read: .snapshot(moved), binding: .bound(codexPane)) == nil)
    // A client that has not typed yet does not move (zellij-live.md): the verification fails, and Open falls back.
    let stayed = try #require(zellijSnapshot())
    #expect(ZellijOpen.verifyPane(openPlan, read: .snapshot(stayed), binding: .bound(codexPane)) == .fallBack(.notVerified, candidates: 1))
    // Another client process, a restarted server, a lost binding or an unread Zellij.
    let otherClient = try #require(zellijSnapshot([labSession(clients: ZellijListing.clientsHeader + "\n1 terminal_1 x\n")],
                                                  table: processTable(psOutput.replacingOccurrences(of: "49075   901", with: "49999   901"))))
    #expect(ZellijOpen.verifyPane(openPlan, read: .snapshot(otherClient), binding: .bound(codexPane)) == .fallBack(.notVerified, candidates: 1))
    let restarted = try #require(zellijSnapshot([labSession(clients: ZellijListing.clientsHeader + "\n1 terminal_1 x\n")],
                                                table: processTable(startTimes: [49121: 1_791_800_000])))
    #expect(ZellijOpen.verifyPane(openPlan, read: .snapshot(restarted), binding: .bound(codexPane)) == .fallBack(.notVerified, candidates: 1))
    #expect(ZellijOpen.verifyPane(openPlan, read: .snapshot(moved), binding: .unavailable(.titleChanged)) == .fallBack(.notVerified, candidates: 1))
    #expect(ZellijOpen.verifyPane(openPlan, read: .unreadable(.commandFailed), binding: .bound(codexPane)) == .fallBack(.notVerified, candidates: 1))
}

@Test func zellijOpenSequenceStopsAtTheFirstFailureAndAHostFailureIsAPartialReach() async {
    final class Calls: @unchecked Sendable { var steps: [String] = [] }
    let calls = Calls()
    let failed = await ZellijOpen.run(now: { 100 },
                                      revalidate: { calls.steps.append("revalidate"); return .success(openPlan) },
                                      focus: { _ in calls.steps.append("focus"); return nil },
                                      verifyPane: { _ in calls.steps.append("verifyPane"); return .fallBack(.notVerified, candidates: 1) },
                                      raise: { _ in calls.steps.append("raise"); return nil },
                                      verifyHost: { _ in calls.steps.append("verifyHost"); return nil })
    #expect(failed == .failed(.fallBack(.notVerified, candidates: 1), at: .verifyPane))
    #expect(calls.steps == ["revalidate", "focus", "verifyPane"])
    let partial = await ZellijOpen.run(now: { 100 }, revalidate: { .success(openPlan) }, focus: { _ in nil },
                                       verifyPane: { _ in nil }, raise: { _ in .fallBack(.notVerified, candidates: 1) },
                                       verifyHost: { _ in nil })
    #expect(partial == .failed(.fallBack(.partialReach, candidates: 1), at: .raise))
    let opened = await ZellijOpen.run(now: { 100 }, revalidate: { .success(openPlan) }, focus: { _ in nil },
                                      verifyPane: { _ in nil }, raise: { _ in nil }, verifyHost: { _ in nil })
    #expect(opened == .opened(openPlan, preOpenAt: 100))
}

// MARK: - Typed input (ADR 0017)

private let inputPane = TypedInputPane(host: .zellij, paneID: "lab/terminal_1", tty: nil)

@Test func zellijTypesTextWithWriteCharsThenASeparateCarriageReturn() {
    #expect(ZellijInput.arguments(.text("-run the tests"), into: inputPane)
            == ["--session", "lab", "action", "write-chars", "--pane-id", "terminal_1", "--", "-run the tests"])
    // Claude submits text plus CR from one write-chars (zellij-live.md, "TUI prompt").
    #expect(ZellijInput.arguments(.textAndSubmit("hi"), into: inputPane)
            == ["--session", "lab", "action", "write-chars", "--pane-id", "terminal_1", "--", "hi\r"])
    #expect(ZellijInput.arguments(.submit, into: inputPane) == ["--session", "lab", "action", "write", "--pane-id", "terminal_1", "13"])
    #expect(TypedReplyWrites.plan(agent: .codex, text: "go").map { ZellijInput.arguments($0, into: inputPane) }
            == [["--session", "lab", "action", "write-chars", "--pane-id", "terminal_1", "--", "go"],
                ["--session", "lab", "action", "write", "--pane-id", "terminal_1", "13"]])
    // A pane of another host, or a malformed handle, is never written.
    #expect(ZellijInput.arguments(.text("x"), into: TypedInputPane(host: .tmux, paneID: "%0", tty: "/dev/ttys017")) == nil)
    #expect(ZellijInput.arguments(.text("x"), into: TypedInputPane(host: .zellij, paneID: "lab", tty: nil)) == nil)
}

@Test func zellijWriteGoesOnlyWhenTheBoundPaneStillExistsUnderTheSameServer() throws {
    // `write-chars` to an unknown pane exits 0 and writes nothing (zellij-live.md), so exit 0 proves
    // nothing about the target: the pane is re-read immediately before every write.
    let snapshot = try #require(zellijSnapshot())
    #expect(ZellijInput.writeAllowed(codexPane, expected: server, current: snapshot))
    #expect(!ZellijInput.writeAllowed(ZellijPaneTarget(session: "lab", paneID: 9), expected: server, current: snapshot))
    #expect(!ZellijInput.writeAllowed(codexPane, expected: server, current: nil))
    #expect(!ZellijInput.writeAllowed(codexPane, expected: nil, current: snapshot))
    // A restarted server reuses pane ids.
    #expect(!ZellijInput.writeAllowed(codexPane, expected: ZellijServerIdentity(pid: 49121, startedAt: 1), current: snapshot))
    // A pane that now shares its tab.
    let split = labTabs.replacingOccurrences(of: tabJSON(1), with: tabJSON(1, tiled: 2))
    #expect(!ZellijInput.writeAllowed(codexPane, expected: server, current: try #require(zellijSnapshot([labSession(tabs: split)]))))
}

@Test func zellijWriteThatDoesNotReturnInTimeCountsAsSent() {
    #expect(ZellijInput.delivery(.succeeded("")) == .written)
    #expect(ZellijInput.delivery(.failed(stderr: "There is no active session!")) == .notWritten)
    #expect(ZellijInput.delivery(.notLaunched) == .notWritten)
    #expect(ZellijInput.delivery(.timedOut) == .possiblyWritten)
}

@Test func zellijReplyRouteNeedsTheBoundPaneAndItsPaneLayer() throws {
    #expect(TerminalHost.zellij.typesReplies)
    let snapshot = try #require(zellijSnapshot())
    #expect(ZellijInput.route(.bound(codexPane), snapshot: snapshot) == .pane(inputPane))
    let nested = psOutput.replacingOccurrences(of: "  901   900 ttys017  -zsh", with: "  901   880 ttys017  -zsh\n  880     1 ??       /opt/homebrew/bin/tmux")
    #expect(ZellijInput.route(.bound(codexPane), snapshot: try #require(zellijSnapshot(table: processTable(nested)))) == .unreachable)
    #expect(ZellijInput.route(.bound(codexPane), snapshot: nil) == .unreachable)
    #expect(ZellijInput.route(.unavailable(.split), snapshot: snapshot) == .unreachable)
    #expect(ZellijInput.route(.notInZellij, snapshot: snapshot) == nil)
    // Input needs the pane layer only, not the host-tab join (ADR 0017): a second client still types.
    let second = try #require(zellijSnapshot(table: processTable(psOutput + "49615   950 ttys024  /opt/homebrew/bin/zellij\n")))
    #expect(ZellijInput.route(.bound(codexPane), snapshot: second) == .pane(inputPane))
    // A Zellij-carried title the shared rules cannot bind is left to Zellij's own route, never another pane.
    #expect(TerminalReplyRoute.from(.unavailable(.ttyUnknown(.zellij))) == nil)
}

// MARK: - Question digits (ADR 0017 "Codex questions"): built, off until a live proof

@Test func zellijQuestionDigitsStayOffUntilTheLiveProofFlipsTheirGate() throws {
    #expect(ZellijInput.questionDigitsProvenLive == false)
    #expect(TerminalHost.zellij.typesQuestionDigits == ZellijInput.questionDigitsProvenLive)
    let question = AttentionQuestion(source: .cli, session: codexSession, turn: UUID(uuidString: "01A129C9-0000-7000-8000-000000000001")!,
                                     callID: "call_1", arrivedAt: 10)
    #expect(QuestionRelayRouting.route(for: question, book: AppServerQuestionBook(), daemonConnected: false,
                                       ledger: QuestionRelayLedger(), progress: nil, herdr: .notInHerdr,
                                       terminalHost: .zellij) == .relayUnavailable(.noQuestionKeys(.zellij)))
    #expect(HerdrQuestionRelayUnavailable.noQuestionKeys(.zellij).message == "Answer this in Codex.")
    #expect(QuestionRelayRouting.route(for: question, book: AppServerQuestionBook(), daemonConnected: false,
                                       ledger: QuestionRelayLedger(), progress: nil, herdr: .notInHerdr,
                                       terminalHost: .zellij, typesDigits: { $0 == .zellij }) == .terminalRelay)
    // One digit, never followed by a carriage return, after the fresh check names the same pane.
    #expect(ZellijInput.digitArguments("2", into: inputPane)
            == ["--session", "lab", "action", "write-chars", "--pane-id", "terminal_1", "--", "2"])
    var pending = ReminderReader.RolloutEvidence()
    pending.pendingQuestions = [question]
    let snapshot = try #require(zellijSnapshot())
    #expect(TerminalQuestionKeys.preSendCheck(question: question, evidence: pending,
                                              route: ZellijInput.route(.bound(codexPane), snapshot: snapshot), spent: inputPane) == nil)
    #expect(TerminalQuestionKeys.preSendCheck(question: question, evidence: pending,
                                              route: ZellijInput.route(.bound(ZellijPaneTarget(session: "lab", paneID: 2)), snapshot: snapshot),
                                              spent: inputPane) == .paneChanged)
}

// MARK: - Visits (ADR 0016 "Visible")

@Test func zellijPaneIsVisibleWhenTheOneClientShowsItInTheFrontHostTab() throws {
    let moved = try #require(zellijSnapshot([labSession(clients: ZellijListing.clientsHeader + "\n1 terminal_1 x\n")]))
    #expect(ZellijVisibility.reading(moved, hostFront: .visible(hostTTY)) == .visible("lab/terminal_1"))
    // The client shows a split pane: no visit target.
    #expect(ZellijVisibility.reading(try #require(zellijSnapshot()), hostFront: .visible(hostTTY)) == .nothing)
    #expect(ZellijVisibility.reading(moved, hostFront: .visible("/dev/ttys030")) == .nothing)
    #expect(ZellijVisibility.reading(moved, hostFront: .nothing) == .nothing)
    #expect(ZellijVisibility.reading(moved, hostFront: .unknown) == .unknown)
    #expect(ZellijVisibility.reading(nil, hostFront: .visible(hostTTY)) == .unknown)
    // A second client process: the client in front cannot be tied to a session.
    let second = try #require(zellijSnapshot([labSession(clients: ZellijListing.clientsHeader + "\n1 terminal_1 x\n")],
                                             table: processTable(psOutput + "49615   950 ttys024  /opt/homebrew/bin/zellij\n")))
    #expect(ZellijVisibility.reading(second, hostFront: .visible(hostTTY)) == .nothing)
}

// MARK: - Settings card (product.md, "Agreed terminal host presentation")

@Test func zellijCardSaysWhenNoTerminalIsOn() {
    let row = ZellijPresentation.settingsRow(on: true, anyTerminalOn: false, read: nil, sessionsSeen: false)
    #expect(row.badge == .needsAttention)
    #expect(row.problems == ["Turn on the terminal you run Zellij in."])
    #expect(ZellijPresentation.settingsRow(on: false, anyTerminalOn: false, read: nil, sessionsSeen: false).badge == .off)
}

@Test func zellijCardListsTheVersionFloorASecondClientAndUnreadableReads() throws {
    let old = ZellijPresentation.settingsRow(on: true, anyTerminalOn: true,
                                             read: .unsupportedVersion(ZellijVersion(major: 0, minor: 43, patch: 1), running: false),
                                             sessionsSeen: false)
    #expect(old.badge == .needsAttention)
    #expect(old.problems == [ZellijPresentation.versionLine])
    #expect(ZellijPresentation.versionLine.contains("0.44.1"))
    let second = try #require(zellijSnapshot(table: processTable(psOutput + "49615   950 ttys024  /opt/homebrew/bin/zellij\n")))
    #expect(ZellijPresentation.settingsRow(on: true, anyTerminalOn: true, read: .snapshot(second), sessionsSeen: true).problems
            == [ZellijPresentation.secondClientLine])
    // product.md names no line for these: the shared not-found and can't-read patterns, as tmux's and WezTerm's cards.
    #expect(ZellijPresentation.settingsRow(on: true, anyTerminalOn: true, read: .binaryNotFound, sessionsSeen: false).problems
            == ["Herdly can't find Zellij in /opt/homebrew/bin or /usr/local/bin."])
    #expect(ZellijPresentation.settingsRow(on: true, anyTerminalOn: true, read: .untrustedSocket, sessionsSeen: false).problems
            == [OpenUnavailableReason.hostUnreadable(.zellij).cardLine])
    #expect(ZellijPresentation.settingsRow(on: true, anyTerminalOn: true, read: .unreadable(.commandFailed), sessionsSeen: false).problems
            == [OpenUnavailableReason.hostUnreadable(.zellij).cardLine])
    // A stale socket gets the same agreed line; its detail goes to diagnostics only.
    #expect(ZellijPresentation.settingsRow(on: true, anyTerminalOn: true, read: .unreadable(.staleSocket), sessionsSeen: false).problems
            == [OpenUnavailableReason.hostUnreadable(.zellij).cardLine])
    #expect(ZellijUnreadable.staleSocket.diagnostic.contains("refuses"))
    let ready = ZellijPresentation.settingsRow(on: true, anyTerminalOn: true, read: .snapshot(try #require(zellijSnapshot())), sessionsSeen: true)
    #expect(ready.badge == .ready && ready.problems.isEmpty)
    #expect(ZellijPresentation.settingsRow(on: true, anyTerminalOn: true, read: .notRunning, sessionsSeen: false).badge == .notInUse)
    #expect(!ZellijPresentation.howOpenWorks.contains("Codex questions"))
    #expect(TerminalHost.zellij.showsCard == false)
}

@Test func zellijClientJoinsAnyEnabledHostsTabByItsTTY() {
    #expect(MultiplexerHostTab.join(clientTTY: hostTTY, switches: zellijSwitches, inventories: [.wezTerm: wezTermTabs()])
            == .tab(hostTab))
    // A split host tab falls back.
    let split: TerminalHostInventory = .tabs([TerminalTab(tabID: "8", tty: hostTTY, title: "lab | x", paneCount: 2)])
    #expect(MultiplexerHostTab.join(clientTTY: hostTTY, switches: zellijSwitches, inventories: [.wezTerm: split])
            == .miss(.fallBack(.unsupportedLayout, candidates: 1)))
}

// MARK: - Fail closed beside a refusing socket (ADR 0014 "never list-sessions")

/// Herdly's side of a read or send, recorded: every `zellij` command it would run, and the answers.
private final class FakeZellij: @unchecked Sendable {
    var sockets: [String: ZellijSocketPeer]
    var binary = true
    var version = "zellij 0.45.1\n"
    var commands: [[String]] = []
    var directory: TmuxFileFacts? = TmuxFileFacts(kind: .directory, owner: 501, mode: 0o700)

    init(sockets: [String: ZellijSocketPeer]) { self.sockets = sockets }

    var effects: ZellijEffects {
        ZellijEffects(
            socketDirectory: socketDirectory, me: 501,
            listing: { [self] in
                ZellijDirectoryListing(base: TmuxFileFacts(kind: .directory, owner: 501, mode: 0o700), directory: directory,
                                       sockets: sockets.mapValues { _ in TmuxFileFacts(kind: .socket, owner: 501, mode: 0o1700) })
            },
            probe: { [self] path in sockets[(path as NSString).lastPathComponent] ?? .refused },
            binaryPresent: { [self] in binary },
            run: { [self] arguments in
                commands.append(arguments)
                if arguments == ["--version"] { return .succeeded(version) }
                switch Array(arguments.dropFirst(3)) {
                case ["list-panes", "--json", "--all"]: return .succeeded(labPanes)
                case ["list-tabs", "--json"]: return .succeeded(labTabs)
                case ["list-clients"]: return .succeeded(labClients)
                default: return .succeeded("")
                }
            },
            processTable: { processTable() })
    }

    /// Commands that address a session (`--session …`), which sweep refusing sockets.
    var sessionCommands: [[String]] { commands.filter { $0.first == "--session" } }
}

@Test func zellijReadRunsNoZellijCommandBesideASocketThatRefusesAConnection() {
    // A crashed session's socket stays behind; any `zellij action` would delete it (isolated 0.45.1 run).
    let fake = FakeZellij(sockets: ["lab": .currentUser, "crashed": .refused])
    #expect(ZellijReader.read(fake.effects) == .unreadable(.staleSocket))
    #expect(fake.commands.isEmpty)
    // A stale socket alone, with Zellij installed: still no command, still unreadable.
    let alone = FakeZellij(sockets: ["crashed": .refused])
    #expect(ZellijReader.read(alone.effects) == .unreadable(.staleSocket))
    #expect(alone.commands.isEmpty)
}

@Test func zellijSendRunsNoZellijCommandBesideASocketThatRefusesAConnection() {
    let fake = FakeZellij(sockets: ["lab": .currentUser, "crashed": .refused])
    let arguments = ["--session", "lab", "action", "write-chars", "--pane-id", "terminal_1", "--", "hi"]
    #expect(ZellijReader.send(arguments, to: codexPane, expecting: server, effects: fake.effects) == .failed(stderr: ""))
    #expect(fake.commands.isEmpty)
}

@Test func zellijReadsAndSendsNormallyWhenEverySocketAccepts() throws {
    let fake = FakeZellij(sockets: ["lab": .currentUser])
    let read = ZellijReader.read(fake.effects)
    #expect(read.snapshot?.sessions.map(\.name) == ["lab"])
    #expect(read.snapshot == zellijSnapshot())
    #expect(fake.sessionCommands.count == 3)
    let arguments = ["--session", "lab", "action", "write-chars", "--pane-id", "terminal_1", "--", "hi"]
    fake.commands = []
    #expect(ZellijReader.send(arguments, to: codexPane, expecting: server, effects: fake.effects) == .succeeded(""))
    // The pane is re-read immediately before the write, then the write goes once.
    #expect(fake.commands.last == arguments)
    #expect(fake.commands.filter { $0 == arguments }.count == 1)
    // A pane that is gone (an unknown id would exit 0 writing nothing) gets nothing.
    fake.commands = []
    let gone = ZellijPaneTarget(session: "lab", paneID: 9)
    #expect(ZellijReader.send(arguments, to: gone, expecting: server, effects: fake.effects) == .failed(stderr: ""))
    #expect(!fake.commands.contains(arguments))
    // A session whose socket is gone gets nothing either.
    fake.commands = []
    #expect(ZellijReader.send(arguments, to: ZellijPaneTarget(session: "other", paneID: 1), expecting: server,
                              effects: fake.effects) == .failed(stderr: ""))
    #expect(fake.commands.isEmpty)
}

@Test func zellijWithoutABinaryOrALiveSessionHoldsNothing() {
    // No binary and nothing accepting: a leftover socket file does not block every host's binding.
    let leftover = FakeZellij(sockets: ["crashed": .refused])
    leftover.binary = false
    #expect(ZellijReader.read(leftover.effects) == .notRunning)
    // A session accepts but the binary is gone: it cannot be read.
    let missing = FakeZellij(sockets: ["lab": .currentUser])
    missing.binary = false
    #expect(ZellijReader.read(missing.effects) == .binaryNotFound)
    #expect(missing.commands.isEmpty)
    // No directory at all; an installed Zellij too old to address sessions with nothing running.
    let none = FakeZellij(sockets: [:])
    none.directory = nil
    #expect(ZellijReader.read(none.effects) == .notRunning)
    let old = FakeZellij(sockets: [:])
    old.version = "zellij 0.43.1\n"
    #expect(ZellijReader.read(old.effects) == .unsupportedVersion(ZellijVersion(major: 0, minor: 43, patch: 1), running: true))
    // Another user's server behind a socket, or an untrusted directory: unreadable, nothing run.
    let foreign = FakeZellij(sockets: ["lab": .otherUser])
    #expect(ZellijReader.read(foreign.effects) == .untrustedSocket)
    #expect(foreign.sessionCommands.isEmpty)
    let unreadableVersion = FakeZellij(sockets: ["lab": .currentUser])
    unreadableVersion.version = "garbage"
    #expect(ZellijReader.read(unreadableVersion.effects) == .unreadable(.versionUnreadable))
    #expect(unreadableVersion.sessionCommands.isEmpty)
}
