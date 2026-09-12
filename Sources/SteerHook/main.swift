import Foundation
import SteerCore

let arguments = CommandLine.arguments

func writeEvent(_ object: [String: Any], to directory: URL, installationID: String) -> Bool {
    guard let event = object["hook_event_name"] as? String, !event.isEmpty,
          let session = object["session_id"] as? String, UUID(uuidString: session) != nil else { return false }
    let now = Date()
    var record: [String: Any] = [
        "hook_event_name": event, "session_id": session, "source": "steer-hook-v1",
        "installation_id": installationID, "received_at": ISO8601DateFormatter().string(from: now),
        "captured_at": now.timeIntervalSince1970
    ]
    if let turn = object["turn_id"] as? String { record["turn_id"] = turn }
    guard JSONSerialization.isValidJSONObject(record),
          let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
          (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return false }
    let temporary = directory.appendingPathComponent(".steer-" + UUID().uuidString)
    let destination = directory.appendingPathComponent(UUID().uuidString + ".json")
    do {
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return true
    } catch {
        try? FileManager.default.removeItem(at: temporary)
        return false
    }
}

private func update(_ request: ApprovalRequest, outcome: ApprovalDecision, in directory: URL) {
    let terminal = ApprovalRequest(requestID: request.requestID, sessionID: request.sessionID, turnID: request.turnID,
                                   details: request.details, receivedAt: request.receivedAt,
                                   expiresAt: request.expiresAt, outcome: outcome)
    guard let data = try? JSONEncoder().encode(terminal) else { return }
    try? data.write(to: ApprovalStore.requestURL(in: directory, id: request.id), options: .atomic)
}

func selfTest() -> Int32 {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steer-hook-self-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = UUID(), turn = UUID()
    let object: [String: Any] = ["hook_event_name": "SessionStart", "session_id": session.uuidString]
    guard writeEvent(object, to: directory, installationID: "self-test"),
          let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil), files.count == 1 else { return 1 }
    let request = ApprovalRequest(requestID: UUID(), sessionID: session, turnID: turn,
                                  details: ApprovalDetails(command: "touch marker"), receivedAt: 100)
    let bashPayload: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": session.uuidString,
                                      "turn_id": turn.uuidString, "tool_name": "Bash",
                                      "tool_input": ["command": "touch marker"]]
    guard ApprovalStore.publish(request, in: directory),
          ApprovalRequestParser.request(from: bashPayload) != nil,
          ApprovalStore.publish(ApprovalDecisionRecord(requestID: request.id, decision: .allowOnce, decidedAt: 101), in: directory),
          ApprovalCoordinator(requestID: request.id, expiresAt: 130).decide(requestID: request.id, decision: .allowOnce, at: 101) == .allowOnce else { return 1 }
    return 0
}

if arguments.contains("--self-test") { exit(selfTest()) }
guard let index = arguments.firstIndex(of: "--events-dir"), arguments.indices.contains(index + 1),
      let installationIndex = arguments.firstIndex(of: "--installation-id"), arguments.indices.contains(installationIndex + 1),
      UUID(uuidString: arguments[installationIndex + 1]) != nil else { exit(0) }
let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
let input = (try? FileHandle.standardInput.read(upToCount: 64 * 1024)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
guard let object = input else { exit(0) }
guard object["hook_event_name"] as? String == "PermissionRequest" else {
    _ = writeEvent(object, to: directory, installationID: arguments[installationIndex + 1]); exit(0)
}
let receiptStarted = Date().timeIntervalSince1970
let receiptStartedUptime = ProcessInfo.processInfo.systemUptime
guard let published = ApprovalRequestParser.request(from: object),
      ApprovalStore.publish(published, in: directory),
      ProcessInfo.processInfo.systemUptime - receiptStartedUptime <= ApprovalTiming.connectionTimeout else { exit(0) }
guard let companionReceipt = ApprovalHelper.awaitReceipt(for: published, publishedAt: receiptStarted, in: directory) else {
    update(published, outcome: .noDecision, in: directory)
    exit(0)
}
let request = ApprovalRequest(requestID: published.id, sessionID: published.sessionID, turnID: published.turnID,
                              details: published.details, receivedAt: companionReceipt.receivedAt,
                              expiresAt: companionReceipt.expiresAt, outcome: .pending)
let decision = ApprovalHelper.awaitDecision(for: request, in: directory)
update(request, outcome: decision, in: directory)
if let output = ApprovalHelper.hookOutput(for: decision) { FileHandle.standardOutput.write(output) }
