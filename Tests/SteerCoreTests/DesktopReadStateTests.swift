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
    let acknowledged = DesktopReadAcknowledgment.acknowledged(completions, snapshot: snapshot)
    // Viewed thread: both turns, including the uncertain restored one. Fresh completion: the file
    // was written under the margin after it arrived, so its flag may not be persisted yet.
    #expect(Set(acknowledged) == Set([completions[0].id, completions[4].id]))

    let exactlyAtMargin = DesktopReadStateSnapshot(unread: [], modifiedAt: 1_998 + DesktopReadAcknowledgment.settleMargin)
    #expect(Set(DesktopReadAcknowledgment.acknowledged(completions, snapshot: exactlyAtMargin))
            == Set(completions.filter { $0.source == .desktop }.map(\.id)))

    let stale = DesktopReadStateSnapshot(unread: [], modifiedAt: 500)
    #expect(DesktopReadAcknowledgment.acknowledged(completions, snapshot: stale).isEmpty)
    let badTime = [AttentionCompletion(source: .desktop, session: viewed, turn: UUID(), arrivedAt: .infinity)]
    #expect(DesktopReadAcknowledgment.acknowledged(badTime, snapshot: snapshot).isEmpty)
}

@Test func readAcknowledgmentDismissesQueuedDesktopCompletionsAndPersists() {
    let viewed = UUID(), unread = UUID()
    var queue = AttentionQueue()
    let a = AttentionCompletion(source: .desktop, session: viewed, turn: UUID(), arrivedAt: 10)
    let b = AttentionCompletion(source: .desktop, session: unread, turn: UUID(), arrivedAt: 10)
    queue.apply(completions: [a, b])
    let snapshot = DesktopReadStateSnapshot(unread: [unread], modifiedAt: 100)
    for id in DesktopReadAcknowledgment.acknowledged(queue.items.compactMap(\.completion), snapshot: snapshot) {
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
