import Foundation
import Testing
@testable import HerdlyCore

// Issue #359: a session once proved CLI through the app-server daemon (loaded, originator not the
// desktop's) stays CLI while the daemon's loaded list is empty or lacks it, as after a reconnect.
// That memory classifies only: it is not a title proof, so it never ends a session for lacking a tab.

private struct DaemonGapFixture {
    let session = UUID()
    let desktop = UUID()
    let turn = UUID()
    let root: URL
    let events: URL
    let rollouts: URL
    let started: Double

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-daemon-gap-\(UUID().uuidString)")
        events = root.appendingPathComponent("events")
        rollouts = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
        started = RolloutTimestamp.parse("2026-10-23T01:42:00Z")!
        for (id, originator) in [(session, "steer"), (desktop, ReminderReader.desktopOriginator)] {
            try hook(id, "SessionStart", nil, at: 0)
            try hook(id, "UserPromptSubmit", turn, at: 10)
            try hook(id, "Stop", turn, at: 20)
            let rollout = rollouts.appendingPathComponent("rollout-2026-10-23T01-42-00-\(id.uuidString.lowercased()).jsonl")
            let text = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"source\":\"vscode\",\"originator\":\"\(originator)\"}}\n"
                + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(turn)\"}}\n"
            try Data(text.utf8).write(to: rollout)
        }
    }

    func hook(_ id: UUID, _ name: String, _ turn: UUID?, at seconds: Double) throws {
        var object: [String: Any] = ["session_id": id.uuidString, "hook_event_name": name,
                                     "received_at": RolloutTimestamp.format(started + seconds)]
        if let turn { object["turn_id"] = turn.uuidString }
        try JSONSerialization.data(withJSONObject: object).write(to: events.appendingPathComponent("\(UUID().uuidString).json"))
    }

    /// A Ghostty inventory well past the grace that shows neither session's title.
    var tabless: GhosttyInventory { GhosttyInventory(titles: ["zsh"], takenAt: started + 100) }

    func scan(daemonThreads: Set<UUID>, remembered: Set<UUID> = []) -> ReminderScan {
        ReminderReader.scan(events: events, rollouts: rollouts, ghostty: tabless,
                            daemonThreads: daemonThreads, rememberedDaemonCLISessions: remembered)
    }

    func queue(after scan: ReminderScan) -> AttentionQueue {
        var queue = AttentionQueue()
        _ = queue.apply(scan: scan, desktopEvents: DesktopEventReader.read(from: events), now: started + 100)
        return queue
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func aDaemonProvedSessionStaysCLIWhileTheDaemonListIsEmpty() throws {
    let fixture = try DaemonGapFixture()
    defer { fixture.remove() }
    // Loaded: proved CLI, and reported as daemon-proved for the app to remember. The desktop's
    // own thread is never daemon-proved, loaded or not.
    let loaded = fixture.scan(daemonThreads: [fixture.session, fixture.desktop])
    #expect(loaded.cliSessions == [fixture.session])
    #expect(loaded.daemonProvedCLISessions == [fixture.session])
    #expect(loaded.titledCLISessions.isEmpty)

    // Without the memory, a scan in the reconnect gap labels its completion desktop (the bug).
    let forgotten = fixture.queue(after: fixture.scan(daemonThreads: []))
    #expect(forgotten.items.compactMap(\.completion).contains { $0.session == fixture.session && $0.source == .desktop })

    // With it, the session stays CLI and no desktop completion is produced for it.
    let gap = fixture.scan(daemonThreads: [], remembered: loaded.daemonProvedCLISessions)
    #expect(gap.cliSessions == [fixture.session])
    #expect(gap.daemonProvedCLISessions.isEmpty)
    #expect(gap.titledCLISessions.isEmpty)
    let completions = fixture.queue(after: gap).items.compactMap(\.completion)
    #expect(completions.filter { $0.session == fixture.session }.map(\.source) == [.cli])
    // The desktop-originated session is unaffected.
    #expect(completions.filter { $0.session == fixture.desktop }.map(\.source) == [.desktop])
}

@Test func aRememberedDaemonSessionIsNotEndedForLackingATabWhileTheDaemonListIsEmpty() throws {
    let fixture = try DaemonGapFixture()
    defer { fixture.remove() }
    let gap = fixture.scan(daemonThreads: [], remembered: [fixture.session])
    #expect(gap.sessionEnds.isEmpty && gap.endedSessions.isEmpty)
    #expect(gap.awaitingHostInventories.isEmpty)
    #expect(gap.cliState.liveSessions == [fixture.session])
    // Another host's inventory without its title ends nothing either.
    let hosts = ReminderReader.scan(events: fixture.events, rollouts: fixture.rollouts, ghostty: fixture.tabless,
                                    rememberedDaemonCLISessions: [fixture.session],
                                    otherHosts: [.iTerm2: .known(["zsh"], takenAt: fixture.started + 100)])
    #expect(hosts.sessionEnds.isEmpty && hosts.awaitingHostInventories.isEmpty)
    // Still loaded, it ends as before once no tab shows it past the grace.
    let loaded = fixture.scan(daemonThreads: [fixture.session], remembered: [fixture.session])
    #expect(loaded.endedSessions == [fixture.session])
}

@Test func theDaemonMemoryLastsThroughADisconnectAndExpiresOnAnAuthoritativeList() {
    let kept = UUID(), unloaded = UUID(), new = UUID()
    let remembered: Set<UUID> = [kept, unloaded]
    // Disconnected, or connected but not yet polled: the empty list says nothing, keep everything.
    #expect(ReminderReader.rememberedDaemonCLISessions(remembered, provedNow: [new], authoritativeLoaded: nil)
            == [kept, unloaded, new])
    // A polled list on a live connection is authoritative: a session it lacks was unloaded.
    #expect(ReminderReader.rememberedDaemonCLISessions(remembered, provedNow: [new], authoritativeLoaded: [kept, new])
            == [kept, new])
    #expect(ReminderReader.rememberedDaemonCLISessions(remembered, provedNow: [], authoritativeLoaded: []).isEmpty)
}

// The app's path: the scan's classification decides which desktop-labelled completions a prompt clears.
@Test func aPromptInADaemonCLISessionClearsItsDesktopLabelledCompletion() throws {
    let fixture = try DaemonGapFixture()
    defer { fixture.remove() }
    // Queued in the reconnect gap before the memory existed: labelled desktop.
    let forgotten = fixture.queue(after: fixture.scan(daemonThreads: [])).items.compactMap(\.completion)
    #expect(Set(forgotten.map(\.source)) == [.desktop])
    let reply = UUID()
    try fixture.hook(fixture.session, "UserPromptSubmit", reply, at: 30)
    try fixture.hook(fixture.desktop, "UserPromptSubmit", reply, at: 30)
    let scan = fixture.scan(daemonThreads: [fixture.session, fixture.desktop])
    let cleared = CodexReplyAcknowledgment.acknowledged(forgotten, events: scan.cliEvents,
                                                       cliSessions: scan.acknowledgeableCLISessions)
    #expect(cleared == Set(forgotten.filter { $0.session == fixture.session }.map(\.id)))
    #expect(!cleared.isEmpty)
}

// A desktop-originated thread keeps the desktop read-state rule even when something classifies it CLI.
@Test func desktopOriginatedSessionsAreNeverAcknowledgeableByAPrompt() {
    let cli = UUID(), desktop = UUID()
    var scan = ReminderScan()
    scan.cliSessions = [cli, desktop]
    scan.desktopOriginatedSessions = [desktop]
    #expect(scan.acknowledgeableCLISessions == [cli])
}
