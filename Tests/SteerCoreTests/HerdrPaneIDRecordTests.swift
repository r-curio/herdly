import Foundation
import Testing
@testable import SteerCore

@Test func herdrPaneIDAcceptsObservedPaneHandles() {
    #expect(HerdrPaneID.validated("w1:p1") == "w1:p1")
    #expect(HerdrPaneID.validated("w4:p1") == "w4:p1")
    #expect(HerdrPaneID.validated("w12:p345") == "w12:p345")
    #expect(HerdrPaneID.validated(String(repeating: "a", count: HerdrPaneID.maximumLength))
        == String(repeating: "a", count: HerdrPaneID.maximumLength))
}

@Test func herdrPaneIDRejectsMissingEmptyOversizedAndMalformedValues() {
    let rejected: [String?] = [
        nil, "", String(repeating: "a", count: HerdrPaneID.maximumLength + 1),
        " w1:p1", "w1:p1 ", "w1:p1\n", "w1\tp1", "w1/p1", "w1:p1;rm", "w1:p1\u{1b}]2;x\u{7}",
        "w1:p1\u{0}", "wé:p1", "w1：p1", "$HERDR_PANE_ID", "\"w1:p1\""
    ]
    for value in rejected {
        #expect(HerdrPaneID.validated(value) == nil, "\(String(describing: value))")
    }
}

@Test func herdrPaneIDIsReadFromTheInjectedEnvironmentOnly() {
    #expect(HerdrPaneID.value(in: ["HERDR_PANE_ID": "w1:p1"]) == "w1:p1")
    #expect(HerdrPaneID.value(in: [:]) == nil)
    #expect(HerdrPaneID.value(in: ["HERDR_PANE_ID": ""]) == nil)
    #expect(HerdrPaneID.value(in: ["herdr_pane_id": "w1:p1", "HERDR_TAB_ID": "w1:t1"]) == nil)
}

@Test func hookRecordGainsThePaneIDOnlyWhenTheEnvironmentValueIsValid() throws {
    let base: [String: Any] = ["hook_event_name": "SessionStart", "session_id": "session-1",
                               "source": CodexSetupRequirements.helperSource]

    var present = base
    HerdrPaneID.record(from: ["HERDR_PANE_ID": "w1:p1"], into: &present)
    #expect(present[HerdrPaneID.recordKey] as? String == "w1:p1")

    for environment in [[:], ["HERDR_PANE_ID": ""], ["HERDR_PANE_ID": "w1:p1\n"],
                        ["HERDR_PANE_ID": String(repeating: "p", count: 65)]] {
        var record = base
        HerdrPaneID.record(from: environment, into: &record)
        #expect(record[HerdrPaneID.recordKey] == nil)
        #expect(record.count == base.count)
    }

    let data = try JSONSerialization.data(withJSONObject: present, options: [.sortedKeys])
    let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(HerdrPaneID.recorded(in: decoded) == "w1:p1")
}

@Test func recordsWithoutOrWithInvalidPaneIDDecodeAsAbsent() throws {
    let old = Data(#"{"captured_at":1,"hook_event_name":"SessionStart","installation_id":"i","received_at":"2026-10-07T00:00:00Z","session_id":"s","source":"steer-hook-v1"}"#.utf8)
    let oldObject = try #require(try JSONSerialization.jsonObject(with: old) as? [String: Any])
    #expect(HerdrPaneID.recorded(in: oldObject) == nil)
    #expect(HerdrPaneID.recorded(in: [HerdrPaneID.recordKey: 7]) == nil)
    #expect(HerdrPaneID.recorded(in: [HerdrPaneID.recordKey: NSNull()]) == nil)
    #expect(HerdrPaneID.recorded(in: [HerdrPaneID.recordKey: "w1:p1\u{7}"]) == nil)
    #expect(HerdrPaneID.recorded(in: [HerdrPaneID.recordKey: "w1:p1"]) == "w1:p1")
}

@Test func existingCodexAndClaudeReadersAcceptRecordsCarryingThePaneID() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-herdr-pane-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appendingPathComponent("codex"), claude = root.appendingPathComponent("claude")
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)

    let session = UUID().uuidString
    for (index, paneID) in [nil, "w1:p1"].enumerated() {
        var record: [String: Any] = ["hook_event_name": "SessionStart", "session_id": session,
                                     "source": CodexSetupRequirements.helperSource, "installation_id": "i",
                                     "received_at": "2026-10-07T00:00:0\(index)Z", "captured_at": Double(index)]
        if let paneID { record[HerdrPaneID.recordKey] = paneID }
        try JSONSerialization.data(withJSONObject: record).write(to: codex.appendingPathComponent("e\(index).json"))
    }
    #expect(DesktopEventReader.read(from: codex).count == 2)

    for (index, event) in ["SessionStart", "UserPromptSubmit"].enumerated() {
        let record: [String: Any] = ["hook_event_name": event, "session_id": "session-1", "captured_at": Double(index + 1),
                                     "prompt_id": "p1", "prompt": "Inspect",
                                     "source": ClaudeSetupRequirements.helperSource, "installation_id": "install",
                                     HerdrPaneID.recordKey: "w1:p1"]
        try JSONSerialization.data(withJSONObject: record).write(to: claude.appendingPathComponent("e\(index).json"))
    }
    let scan = ClaudeObservationReader.scan(events: claude, sourceScope: claude.path, installationID: "install", now: 10)
    #expect(scan.observations.contains { if case .running = $0 { return true }; return false })
}
