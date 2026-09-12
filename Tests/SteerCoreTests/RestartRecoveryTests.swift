import Foundation
import Testing
@testable import SteerCore

private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

// MARK: Snapshot store

@Test func snapshotRoundTripsCompletionsAndAcknowledgments() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("attention.json")
    let completion = AttentionCompletion(source: .desktop, session: UUID(), turn: UUID(), arrivedAt: 10)
    let acknowledged = CompletionIdentity(source: .cli, session: UUID(), turn: UUID())
    var queue = AttentionQueue(acknowledged: [acknowledged])
    queue.apply(completions: [completion])

    #expect(AttentionSnapshotStore.save(queue.snapshot, to: file))
    let loaded = AttentionSnapshotStore.load(from: file)
    #expect(loaded == queue.snapshot)
    #expect(loaded.completions.map(\.id) == [completion.id])
    #expect(loaded.acknowledged == [acknowledged])
    // Nothing but the snapshot file itself is left behind.
    let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(files == ["attention.json"])
}

@Test func invalidSnapshotsLoadAsEmptyAndDoNotBlockStartup() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("attention.json")
    let empty = AttentionSnapshot()

    #expect(AttentionSnapshotStore.load(from: file) == empty) // missing
    try Data("{not json".utf8).write(to: file)
    #expect(AttentionSnapshotStore.load(from: file) == empty) // corrupt
    try Data("{\"version\":99,\"completions\":[],\"acknowledged\":[]}".utf8).write(to: file)
    #expect(AttentionSnapshotStore.load(from: file) == empty) // unknown version
    let valid = try JSONEncoder().encode(AttentionSnapshot(completions: [
        AttentionCompletion(source: .desktop, session: UUID(), turn: UUID(), arrivedAt: 1)
    ]))
    try valid.prefix(valid.count / 2).write(to: file)
    #expect(AttentionSnapshotStore.load(from: file) == empty) // truncated by an interrupted save
    try Data(repeating: 0x20, count: AttentionSnapshotStore.limit + 1).write(to: file)
    #expect(AttentionSnapshotStore.load(from: file) == empty) // oversized
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    #expect(AttentionSnapshotStore.load(from: file) == empty) // not a regular file
    #expect(!AttentionSnapshotStore.save(AttentionSnapshot(), to: file)) // a directory is never replaced
    try FileManager.default.removeItem(at: file)
    let elsewhere = root.appendingPathComponent("codex-data.json")
    try Data("{\"codex\":true}".utf8).write(to: elsewhere)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
    #expect(AttentionSnapshotStore.load(from: file) == empty) // a symlink is not read
    #expect(!AttentionSnapshotStore.save(AttentionSnapshot(), to: file)) // nor written through
    #expect(try Data(contentsOf: elsewhere) == Data("{\"codex\":true}".utf8))
}

@Test func saveReplacesAtomicallyAndIgnoresLeftoverTemporaryFiles() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("attention.json")
    let first = AttentionSnapshot(completions: [AttentionCompletion(source: .cli, session: UUID(), turn: UUID(), arrivedAt: 1)])
    #expect(AttentionSnapshotStore.save(first, to: file))
    // An interrupted earlier save leaves a temporary file beside the snapshot.
    try Data("garbage".utf8).write(to: root.appendingPathComponent(".attention.json.steer-partial"))
    #expect(AttentionSnapshotStore.load(from: file) == first)

    let second = AttentionSnapshot(acknowledged: [first.completions[0].id])
    #expect(AttentionSnapshotStore.save(second, to: file))
    #expect(AttentionSnapshotStore.load(from: file) == second)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0 != "attention.json" }
    #expect(leftovers == [".attention.json.steer-partial"]) // the store never deletes files it did not write
}

@Test func snapshotNeverContainsRunningWorkOrRequests() {
    let session = UUID(), turn = UUID()
    var queue = AttentionQueue()
    queue.apply(requests: [AttentionRequest(id: UUID(), source: .cli, session: session, turn: turn, arrivedAt: 1)],
                completions: [AttentionCompletion(source: .desktop, session: UUID(), turn: UUID(), arrivedAt: 2)],
                running: [AttentionRunning(source: .desktop, session: UUID(), turn: UUID(), arrivedAt: 3)])
    let restored = AttentionQueue(snapshot: queue.snapshot)
    #expect(restored.workingCount == 0)
    #expect(restored.items.map(\.kind) == [.completion])
}

// MARK: Restored completions

@Test func restoredCompletionsAreUncertainSilentAndIndependentlyDismissible() {
    let session = UUID()
    let older = AttentionCompletion(source: .desktop, session: session, turn: UUID(), arrivedAt: 1)
    let dismissed = AttentionCompletion(source: .desktop, session: session, turn: UUID(), arrivedAt: 2)
    var before = AttentionQueue()
    before.apply(completions: [older, dismissed])
    before.dismiss(.completion(dismissed.id))
    #expect(before.items.compactMap(\.completion).map(\.uncertain) == [false])

    var after = AttentionQueue(snapshot: before.snapshot)
    // A visit while the companion was quit cannot be verified: the item stays, marked uncertain.
    #expect(after.items.compactMap(\.completion).map(\.id) == [older.id])
    #expect(after.items.compactMap(\.completion).map(\.uncertain) == [true])
    // The presentation restored for it never signals a first appearance, so no sound replays.
    var presentation = Attention(restored: true)
    let firstAppearance = presentation.update(codexForeground: false, hovering: false, now: 0)
    #expect(!firstAppearance)
    // The dismissed completion stays cleared when the same records are scanned again.
    after.apply(completions: [older, dismissed])
    #expect(after.items.compactMap(\.completion).map(\.id) == [older.id])
    // A later turn in that session is a new, certain completion that may present and sound.
    let later = AttentionCompletion(source: .desktop, session: session, turn: UUID(), arrivedAt: 3)
    after.apply(completions: [later])
    #expect(after.items.compactMap(\.completion).map(\.uncertain) == [true, false])
    after.dismiss(.completion(older.id))
    #expect(after.items.compactMap(\.completion).map(\.id) == [later.id])
    #expect(after.snapshot.acknowledged.contains(older.id) && after.snapshot.acknowledged.contains(dismissed.id))
}

@Test func completionsFirstSeenByARestoringScanAreUncertainButLiveOnesAreNot() {
    let session = UUID(), turn = UUID()
    var scan = ReminderScan()
    scan.cliCompletions = [CLICompletion(session: session, turn: turn, receivedAt: "1970-01-01T00:00:10Z")]
    var queue = AttentionQueue()
    queue.apply(scan: scan, desktopEvents: [], now: 20, restoring: true)
    #expect(queue.items.compactMap(\.completion).map(\.uncertain) == [true])

    var live = AttentionQueue()
    live.apply(scan: scan, desktopEvents: [], now: 20)
    #expect(live.items.compactMap(\.completion).map(\.uncertain) == [false])
    // A restoring scan cannot downgrade a completion the process already observed live.
    live.apply(scan: scan, desktopEvents: [], now: 21, restoring: true)
    #expect(live.items.compactMap(\.completion).map(\.uncertain) == [false])
}

// MARK: Requests after restart

@Test func savedReceiptAloneNeverRestoresActionableControls() {
    let request = AttentionRequest(id: UUID(), source: .cli, session: UUID(), turn: UUID(), arrivedAt: 100, handoffAfter: 30)
    var scan = ReminderScan()
    scan.attentionRequests = [request] // the reader found a receipt and no decision record on disk
    var queue = AttentionQueue()
    let released = queue.apply(scan: scan, desktopEvents: [], now: 105)
    #expect(released.map(\.identity) == [request.identity])
    #expect(queue.items.first?.kind == .handedBackRequest)
    #expect(queue.items.first?.request?.arrivedAt == request.arrivedAt)
    // Reported once: the app writes one no-decision record, and a later scan does not repeat it.
    #expect(queue.apply(scan: scan, desktopEvents: [], now: 106).isEmpty)
    #expect(queue.items.first?.kind == .handedBackRequest)
}

@Test func receiptIssuedByThisProcessKeepsTheRequestActionableUntilItsDeadline() {
    let request = AttentionRequest(id: UUID(), source: .cli, session: UUID(), turn: UUID(), arrivedAt: 100, handoffAfter: 30)
    var queue = AttentionQueue()
    queue.receipt([request], now: 100)
    #expect(queue.items.first?.kind == .actionableRequest)
    var scan = ReminderScan()
    scan.attentionRequests = [request]
    #expect(queue.apply(scan: scan, desktopEvents: [], now: 110).isEmpty)
    #expect(queue.items.first?.kind == .actionableRequest)
    #expect(queue.apply(scan: scan, desktopEvents: [], now: 130.1).isEmpty)
    #expect(queue.items.first?.kind == .handedBackRequest)
}

@Test func restartDoesNotRestoreRunningSessionsFromTheReaderEither() throws {
    // A rescan rebuilds running work from current evidence only; a session that ended stays ended.
    let session = UUID(), turn = UUID()
    let events: [DesktopEvent] = [.turnStarted(session: session, turn: turn, receivedAt: "01"),
                                  .sessionEnded(session: session, receivedAt: "02")]
    var queue = AttentionQueue(snapshot: AttentionSnapshot())
    queue.apply(scan: ReminderScan(), desktopEvents: events, now: 10, restoring: true)
    #expect(queue.workingCount == 0)
    let stillRunning: [DesktopEvent] = [.turnStarted(session: session, turn: turn, receivedAt: "01")]
    queue.apply(scan: ReminderScan(), desktopEvents: stillRunning, now: 11)
    #expect(queue.workingCount == 1)
}
