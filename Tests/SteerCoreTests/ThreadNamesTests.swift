import Foundation
import Testing
@testable import SteerCore

private func indexLine(_ id: String, _ name: String) -> String {
    "{\"id\":\"\(id)\",\"thread_name\":\"\(name)\",\"updated_at\":\"2026-09-14T02:30:15.871051Z\"}"
}

@Test func threadNamesParseRealShapeWithLastLineWinning() {
    let a = UUID(), b = UUID()
    let text = [indexLine(a.uuidString.lowercased(), "Run LFG for issue 9"),
                indexLine(b.uuidString, "  Sync main and resolve conflicts  "),
                indexLine(a.uuidString.lowercased(), "Run LFG for issue 7")].joined(separator: "\n") + "\n"
    let names = ThreadNameReader.parse(Data(text.utf8))
    #expect(names == [a: "Run LFG for issue 7", b: "Sync main and resolve conflicts"])
    #expect(ThreadNameReader.parse(Data()).isEmpty)
}

@Test func threadNamesSkipUnreadableLinesWithoutDroppingOthers() {
    let good = UUID()
    let text = ["not json",
                "[]",
                "{\"id\":\"thread-1\",\"thread_name\":\"bad id\"}",
                "{\"id\":\"\(UUID().uuidString)\",\"thread_name\":\"   \"}",
                "{\"id\":\"\(UUID().uuidString)\",\"thread_name\":42}",
                "{\"id\":\"\(UUID().uuidString)\"}",
                indexLine(good.uuidString, "Diagnose BCC production issue"),
                "{\"id\":\"\(UUID().uuidString)\",\"thread_na"].joined(separator: "\n")
    #expect(ThreadNameReader.parse(Data(text.utf8)) == [good: "Diagnose BCC production issue"])
}

@Test func threadNamesReaderRespectsFileBounds() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = ThreadNameReader.defaultURL(codexHome: root)
    #expect(file.lastPathComponent == "session_index.jsonl")
    #expect(ThreadNameReader.read(file) == nil)

    let session = UUID()
    try Data((indexLine(session.uuidString, "Sync main and resolve conflicts") + "\n").utf8).write(to: file)
    #expect(ThreadNameReader.read(file) == [session: "Sync main and resolve conflicts"])

    let link = root.appendingPathComponent("link.jsonl")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(ThreadNameReader.read(link) == nil)

    let padding = String(repeating: " ", count: ThreadNameReader.limit + 1)
    try Data((indexLine(session.uuidString, "x") + "\n" + padding).utf8).write(to: file)
    #expect(ThreadNameReader.read(file) == nil)
}

@Test func stripPrefersThreadNameOverTaskNameAndIdentifier() {
    let named = UUID(uuidString: "01A0916C-337B-4C2E-9C1E-000000000002")!
    let names = [named: "Sync main and resolve conflicts"]
    #expect(StripSummary.sessionLabel(named, names: names) == "Sync main and resolve conflicts")
    #expect(StripSummary.sessionLabel(UUID(), names: names).hasPrefix("session "))
    #expect(StripSummary.sessionLabel(named) == "session 01a0916c")

    let details = ApprovalDetails(taskName: "fix auth bug", project: "steer", action: "run", command: "swift test", reason: nil)
    let request = AttentionRequest(id: UUID(), source: .desktop, session: named, turn: UUID(), arrivedAt: 2, details: details)
    var queue = AttentionQueue()
    queue.apply(requests: [request], completions: [], now: 2)
    #expect(StripSummary.make(items: queue.items, testPending: false, names: names).subject == "Sync main and resolve conflicts")
    #expect(StripSummary.make(items: queue.items, testPending: false).subject == "fix auth bug")
}
