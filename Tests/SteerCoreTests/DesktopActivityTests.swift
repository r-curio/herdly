import Foundation
import Testing
@testable import SteerCore

@Test func desktopReplayShowsRunningTurnThenRetainsCompletion() {
    let session = UUID(), turn = UUID()
    var state = DesktopState()

    state.apply(.sessionStarted(session: session, receivedAt: "01"))
    state.apply(.turnStarted(session: session, turn: turn, receivedAt: "02"))
    #expect(state.running.map(\.session) == [session])
    #expect(state.completed.isEmpty)
    #expect(state.isVisible(codexForeground: false))
    #expect(!state.isVisible(codexForeground: true))
    #expect(state.isVisible(codexForeground: nil))

    state.apply(.turnCompleted(session: session, turn: turn, receivedAt: "03"))
    #expect(state.running.isEmpty)
    #expect(state.completed.map(\.id) == [TurnIdentity(session: session, turn: turn)])
    #expect(state.isVisible(codexForeground: false))
    #expect(!state.isVisible(codexForeground: true))
    #expect(state.isVisible(codexForeground: nil))

    state.apply(.sessionEnded(session: session, receivedAt: "04"))
    #expect(state.completed.count == 1)
}

@Test func desktopReaderReplaysMetadataOnlyHookFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID(), turn = UUID()
    func write(_ name: String, _ event: String, _ turn: UUID? = nil) throws {
        var value: [String: Any] = ["hook_event_name": event, "session_id": session.uuidString, "received_at": name]
        if let turn { value["turn_id"] = turn.uuidString }
        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name + ".json"))
    }
    try write("01", "SessionStart")
    try write("02", "UserPromptSubmit", turn)
    try write("03", "Stop", turn)
    try write("04", "SessionEnd")

    let replay = DesktopEventReader.read(from: root)
    #expect(replay == [
        .sessionStarted(session: session, receivedAt: "01"),
        .turnStarted(session: session, turn: turn, receivedAt: "02"),
        .turnCompleted(session: session, turn: turn, receivedAt: "03"),
        .sessionEnded(session: session, receivedAt: "04")
    ])
}
