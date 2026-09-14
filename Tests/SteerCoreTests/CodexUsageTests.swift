import Foundation
import Testing
@testable import SteerCore

private func tokenCount(primary: String, secondary: String = "null", timestamp: String = "2026-09-14T03:06:53.274Z") -> String {
    "{\"timestamp\":\"\(timestamp)\",\"ordinal\":19,\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":38652}},"
        + "\"rate_limits\":{\"limit_id\":\"codex\",\"limit_name\":null,\"primary\":\(primary),\"secondary\":\(secondary),"
        + "\"credits\":{\"has_credits\":false,\"unlimited\":false,\"balance\":\"0\"},\"plan_type\":\"pro\",\"rate_limit_reached_type\":null}}}"
}

private func window(_ used: Double, minutes: Int, resets: Int) -> String {
    "{\"used_percent\":\(used),\"window_minutes\":\(minutes),\"resets_at\":\(resets)}"
}

@Test func weeklyLimitParsesTheRealShapeWithTheWeeklyWindowAsPrimary() {
    let text = tokenCount(primary: window(7.0, minutes: 10080, resets: 1789831495)) + "\n"
    #expect(CodexUsageReader.parse(Data(text.utf8))
            == CodexWeeklyLimit(usedPercent: 7, resetsAt: 1789831495, observedAt: "2026-09-14T03:06:53.274Z"))
}

@Test func weeklyLimitPrefersTheTenThousandEightyMinuteWindowWhereverItSits() {
    let text = tokenCount(primary: window(42.5, minutes: 300, resets: 1789800000),
                          secondary: window(63.2, minutes: 10080, resets: 1789831495)) + "\n"
    let limit = CodexUsageReader.parse(Data(text.utf8))
    #expect(limit?.usedPercent == 63.2)
    #expect(limit?.resetsAt == 1789831495)
    #expect(limit?.percentText == "63%")
    // A five-hour window alone is not a weekly reading.
    #expect(CodexUsageReader.parse(Data(tokenCount(primary: window(42.5, minutes: 300, resets: 1789800000)).utf8)) == nil)
}

@Test func weeklyLimitTakesTheLastReadableLineAndSkipsTheRest() {
    let lines = ["{\"type\":\"session_meta\",\"payload\":{\"id\":\"x\"}}",
                 tokenCount(primary: window(5, minutes: 10080, resets: 1789831495)),
                 "not json",
                 "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":null}}",
                 tokenCount(primary: window(9, minutes: 10080, resets: 1789831495)),
                 "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":\"12\",\"window_minutes\":10080}}}}",
                 "{\"timestamp\":\"2026-09-14T03:07:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_co"]
    #expect(CodexUsageReader.parse(Data(lines.joined(separator: "\n").utf8))?.usedPercent == 9)
    #expect(CodexUsageReader.parse(Data()) == nil)
}

@Test func weeklyLimitIsCurrentOnlyUntilTheWindowResets() {
    let limit = CodexWeeklyLimit(usedPercent: 140, resetsAt: 1000)
    #expect(limit.isCurrent(now: 999))
    #expect(!limit.isCurrent(now: 1000))
    #expect(limit.percentText == "100%")
    #expect(CodexWeeklyLimit(usedPercent: -3, resetsAt: 1).percentText == "0%")
    #expect(CodexWeeklyLimit(usedPercent: 7.4, resetsAt: 1).percentText == "7%")
}

@Test func weeklyLimitComesFromTheNewestRolloutThatCarriesOne() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = CodexUsageReader.defaultRoot(codexHome: root)
    #expect(sessions.lastPathComponent == "sessions")
    #expect(CodexUsageReader.latest(root: sessions) == nil)

    func write(_ day: String, _ name: String, _ text: String, modified: Date) throws -> URL {
        let directory = sessions.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }
    let base = Date(timeIntervalSince1970: 1_789_000_000)
    _ = try write("2026/09/11", "rollout-a.jsonl", tokenCount(primary: window(3, minutes: 10080, resets: 1789831495)) + "\n", modified: base)
    _ = try write("2026/09/13", "rollout-b.jsonl", tokenCount(primary: window(7, minutes: 10080, resets: 1789831495)) + "\n", modified: base.addingTimeInterval(60))
    // The newest file is a session that has not reported usage yet; the reading falls through to the one before it.
    _ = try write("2026/09/14", "rollout-c.jsonl", "{\"type\":\"session_meta\",\"payload\":{}}\n", modified: base.addingTimeInterval(120))
    #expect(CodexUsageReader.latest(root: sessions)?.usedPercent == 7)

    // A long rollout is read from its tail only, and the cut first line does not break the read.
    let padding = String(repeating: "{\"type\":\"response_item\",\"payload\":{\"text\":\"" + String(repeating: "x", count: 1000) + "\"}}\n", count: 700)
    let long = padding + tokenCount(primary: window(11, minutes: 10080, resets: 1789831495)) + "\n"
    let longURL = try write("2026/09/14", "rollout-d.jsonl", long, modified: base.addingTimeInterval(180))
    #expect(long.utf8.count > CodexUsageReader.tailBytes)
    #expect(CodexUsageReader.latest(root: sessions)?.usedPercent == 11)

    // A symlink in place of the newest rollout is never followed.
    let link = sessions.appendingPathComponent("2026/09/14/rollout-e.jsonl")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: longURL)
    try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(240)], ofItemAtPath: link.path)
    #expect(CodexUsageReader.tail(link) == nil)
}
