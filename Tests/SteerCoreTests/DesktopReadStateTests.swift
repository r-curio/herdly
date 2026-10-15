import Foundation
import Testing
@testable import SteerCore

private func globalState(local: [Any]?, extra: [String: Any] = [:]) -> Data {
    var atoms: [String: Any] = ["has-seen-fast-mode-announcement": true]
    if let local { atoms["unread-thread-ids-by-host-v1"] = ["local": local, "ssh:box": ["019f0000-0000-7000-8000-000000000001"]] }
    var root: [String: Any] = ["electron-persisted-atom-state": atoms, "project-order": []]
    for (key, value) in extra { root[key] = value }
    return try! JSONSerialization.data(withJSONObject: root)
}

@Test func readStateParsesLocalUnreadSetOnly() throws {
    let a = UUID(), b = UUID()
    let snapshot = try #require(DesktopReadStateReader.parse(globalState(local: [a.uuidString.lowercased(), b.uuidString]), modifiedAt: 100))
    #expect(snapshot.unread == [a, b])
    #expect(snapshot.modifiedAt == 100)
    let empty = try #require(DesktopReadStateReader.parse(globalState(local: []), modifiedAt: 5))
    #expect(empty.unread.isEmpty)
}

/// The per-identity layout from desktop 26.930.61225: identity key → execution host key → ids.
private func identityState(_ identities: [String: [String: Any]], version: Any = 1, legacyLocal: [Any]? = nil) -> Data {
    var atoms: [String: Any] = ["has-seen-fast-mode-announcement": true]
    if let legacyLocal { atoms["unread-thread-ids-by-host-v1"] = ["local": legacyLocal] }
    let state: [String: Any] = [
        "version": version,
        "unreadByIdentity": identities,
        "legacyMigration": ["identityKey": "3430d589", "unreadThreadIdsByHostId": ["local": []], "adoptedHostIds": ["local": "local:092af2cb"]],
    ]
    return try! JSONSerialization.data(withJSONObject: ["electron-persisted-atom-state": atoms, "electron-thread-read-state-v1": state])
}

@Test func readStateParsesTheLocalHostOfTheOnlyIdentity() throws {
    let a = UUID(), b = UUID(), cloud = UUID()
    let data = identityState(["3430d589": ["local:092af2cb": [a.uuidString.lowercased(), b.uuidString], "durable:431f7bac": [cloud.uuidString]]])
    let snapshot = try #require(DesktopReadStateReader.parse(data, modifiedAt: 100))
    #expect(snapshot.unread == [a, b])
    let empty = try #require(DesktopReadStateReader.parse(identityState(["3430d589": ["local:092af2cb": []]]), modifiedAt: 5))
    #expect(empty.unread.isEmpty)
    // A stale legacy copy beside the current layout is ignored rather than merged.
    let withLegacy = identityState(["3430d589": ["local:092af2cb": [a.uuidString]]], legacyLocal: [b.uuidString])
    #expect(try #require(DesktopReadStateReader.parse(withLegacy, modifiedAt: 1)).unread == [a])
}

@Test func readStateFailsClosedWhenTheLocalHostIsAmbiguous() {
    let id = UUID().uuidString
    // No identity (after a logout clears it), or two accounts: Steer cannot tell which is current.
    #expect(DesktopReadStateReader.parse(identityState([:]), modifiedAt: 1) == nil)
    #expect(DesktopReadStateReader.parse(identityState(["a": ["local:1": [id]], "b": ["local:1": []]]), modifiedAt: 1) == nil)
    // No local host, or two: absence must never read as "every local thread is read".
    #expect(DesktopReadStateReader.parse(identityState(["a": ["durable:1": [id]]]), modifiedAt: 1) == nil)
    #expect(DesktopReadStateReader.parse(identityState(["a": ["local:1": [id], "local:2": []]]), modifiedAt: 1) == nil)
    #expect(DesktopReadStateReader.parse(identityState(["a": ["local": [id]]]), modifiedAt: 1) == nil)
    // A present but unreadable current layout does not fall back to the legacy key.
    #expect(DesktopReadStateReader.parse(identityState(["a": ["local:1": [id]]], version: 2, legacyLocal: [id]), modifiedAt: 1) == nil)
    #expect(DesktopReadStateReader.parse(identityState(["a": ["local:1": ["thread-1"]]]), modifiedAt: 1) == nil)
    let wrongShape = try! JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": ["version": 1, "unreadByIdentity": ["a": [id]]]])
    #expect(DesktopReadStateReader.parse(wrongShape, modifiedAt: 1) == nil)
}

@Test func readStateFailsClosedOnMissingOrForeignShape() {
    #expect(DesktopReadStateReader.parse(globalState(local: nil), modifiedAt: 1) == nil)
    #expect(DesktopReadStateReader.parse(Data("[]".utf8), modifiedAt: 1) == nil)
    #expect(DesktopReadStateReader.parse(Data("not json".utf8), modifiedAt: 1) == nil)
    #expect(DesktopReadStateReader.parse(globalState(local: [42]), modifiedAt: 1) == nil)
    #expect(DesktopReadStateReader.parse(globalState(local: ["thread-1"]), modifiedAt: 1) == nil)
    #expect(DesktopReadStateReader.parse(globalState(local: [UUID().uuidString]), modifiedAt: .nan) == nil)
    let wrongHostShape = try! JSONSerialization.data(withJSONObject: ["electron-persisted-atom-state": ["unread-thread-ids-by-host-v1": [UUID().uuidString]]])
    #expect(DesktopReadStateReader.parse(wrongHostShape, modifiedAt: 1) == nil)
}

@Test func readStateReaderUsesFileModificationTimeAndBounds() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = DesktopReadStateReader.defaultURL(codexHome: root)
    #expect(file.lastPathComponent == ".codex-global-state.json")
    #expect(DesktopReadStateReader.read(file) == nil)

    let session = UUID()
    try globalState(local: [session.uuidString]).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
    let snapshot = try #require(DesktopReadStateReader.read(file))
    #expect(snapshot.unread == [session])
    #expect(snapshot.modifiedAt == 1_700_000_000)

    let link = root.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(DesktopReadStateReader.read(link) == nil)

    let padding = String(repeating: " ", count: DesktopReadStateReader.limit + 1)
    try (globalState(local: [session.uuidString]) + Data(padding.utf8)).write(to: file)
    #expect(DesktopReadStateReader.read(file) == nil)
}

@Test func readAcknowledgmentRequiresSettledAbsenceForDesktopOnly() {
    let viewed = UUID(), stillUnread = UUID(), fresh = UUID(), cli = UUID()
    let completions = [
        AttentionCompletion(source: .desktop, session: viewed, turn: UUID(), arrivedAt: 1_000),
        AttentionCompletion(source: .desktop, session: stillUnread, turn: UUID(), arrivedAt: 1_000),
        AttentionCompletion(source: .desktop, session: fresh, turn: UUID(), arrivedAt: 1_998),
        AttentionCompletion(source: .cli, session: cli, turn: UUID(), arrivedAt: 1_000),
        AttentionCompletion(source: .desktop, session: viewed, turn: UUID(), arrivedAt: 900, uncertain: true),
    ]
    let snapshot = DesktopReadStateSnapshot(unread: [stillUnread], modifiedAt: 2_000)
    let desktopThreads: Set<UUID> = [viewed, stillUnread, fresh]
    let acknowledged = DesktopReadAcknowledgment.acknowledged(completions, snapshot: snapshot, desktopThreads: desktopThreads)
    // Viewed thread: both turns, including the uncertain restored one. Fresh completion: the file
    // was written under the margin after it arrived, so its flag may not be persisted yet.
    #expect(Set(acknowledged) == Set([completions[0].id, completions[4].id]))

    let exactlyAtMargin = DesktopReadStateSnapshot(unread: [], modifiedAt: 1_998 + DesktopReadAcknowledgment.settleMargin)
    #expect(Set(DesktopReadAcknowledgment.acknowledged(completions, snapshot: exactlyAtMargin, desktopThreads: desktopThreads))
            == Set(completions.filter { $0.source == .desktop }.map(\.id)))

    let stale = DesktopReadStateSnapshot(unread: [], modifiedAt: 500)
    #expect(DesktopReadAcknowledgment.acknowledged(completions, snapshot: stale, desktopThreads: desktopThreads).isEmpty)
    let badTime = [AttentionCompletion(source: .desktop, session: viewed, turn: UUID(), arrivedAt: .infinity)]
    #expect(DesktopReadAcknowledgment.acknowledged(badTime, snapshot: snapshot, desktopThreads: desktopThreads).isEmpty)
}

// Issue #284: a daemon-run terminal session is labelled desktop until Steer proves it CLI. The
// desktop app never flags its thread unread, so absence from the unread set is no evidence.
@Test func readAcknowledgmentIgnoresThreadsTheDesktopAppDidNotCreate() {
    let desktop = UUID(), daemonRun = UUID()
    let completions = [
        AttentionCompletion(source: .desktop, session: desktop, turn: UUID(), arrivedAt: 1_000),
        AttentionCompletion(source: .desktop, session: daemonRun, turn: UUID(), arrivedAt: 1_000),
    ]
    let snapshot = DesktopReadStateSnapshot(unread: [], modifiedAt: 2_000)
    #expect(DesktopReadAcknowledgment.acknowledged(completions, snapshot: snapshot, desktopThreads: [desktop])
            == [completions[0].id])
    #expect(DesktopReadAcknowledgment.acknowledged(completions, snapshot: snapshot, desktopThreads: []).isEmpty)
}

@Test(arguments: [("Codex Desktop", true), ("codex-tui", false), ("steer", false), (nil, false)] as [(String?, Bool)])
func scanNamesOnlyDesktopOriginatedSessions(originator: String?, desktop: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-originator-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID(), turn = UUID()
    for (event, time) in [("SessionStart", "2026-10-15T01:19:59Z"), ("Stop", "2026-10-15T01:20:00Z")] {
        let object: [String: Any] = ["session_id": session.uuidString, "hook_event_name": event,
                                     "turn_id": turn.uuidString, "received_at": time]
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent(UUID().uuidString + ".json"))
    }
    var meta: [String: Any] = ["id": session.uuidString, "source": "vscode"]
    if let originator { meta["originator"] = originator }
    let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": meta])
    try (header + Data("\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(turn)\"}}\n".utf8))
        .write(to: root.appendingPathComponent("rollout-" + session.uuidString.lowercased() + ".jsonl"))
    let scan = ReminderReader.scan(events: root, rollouts: root)
    #expect(scan.desktopOriginatedSessions == (desktop ? [session] : []))
    // Not yet proved CLI either way: its completion stays desktop-labelled, and only a desktop
    // thread's completion can be read-acknowledged.
    #expect(scan.cliSessions.isEmpty)
    let completion = AttentionCompletion(source: .desktop, session: session, turn: turn, arrivedAt: 1_000)
    let acknowledged = DesktopReadAcknowledgment.acknowledged(
        [completion], snapshot: DesktopReadStateSnapshot(unread: [], modifiedAt: 2_000),
        desktopThreads: scan.desktopOriginatedSessions)
    #expect(acknowledged == (desktop ? [completion.id] : []))
}

@Test func readAcknowledgmentDismissesQueuedDesktopCompletionsAndPersists() {
    let viewed = UUID(), unread = UUID()
    var queue = AttentionQueue()
    let a = AttentionCompletion(source: .desktop, session: viewed, turn: UUID(), arrivedAt: 10)
    let b = AttentionCompletion(source: .desktop, session: unread, turn: UUID(), arrivedAt: 10)
    queue.apply(completions: [a, b])
    let snapshot = DesktopReadStateSnapshot(unread: [unread], modifiedAt: 100)
    for id in DesktopReadAcknowledgment.acknowledged(queue.items.compactMap(\.completion), snapshot: snapshot,
                                                         desktopThreads: [viewed, unread]) {
        queue.dismiss(.completion(id))
    }
    #expect(queue.items.compactMap(\.completion).map(\.id) == [b.id])
    #expect(queue.acknowledgedCompletions == [a.id])
    // The acknowledgment survives a rescan that offers the same completion again.
    queue.apply(completions: [a])
    #expect(queue.items.compactMap(\.completion).map(\.id) == [b.id])
    let restored = AttentionQueue(snapshot: queue.snapshot)
    #expect(restored.acknowledgedCompletions == [a.id])
}
