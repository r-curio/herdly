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

private func jsonText(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let value = value as? String { return value }
    guard JSONSerialization.isValidJSONObject(value), let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return nil }
    return String(data: bytes, encoding: .utf8)
}

private func supportedPermission(_ object: [String: Any]) -> Bool {
    let kind = (object["permission_type"] as? String ?? object["kind"] as? String ?? object["tool_name"] as? String)?.lowercased()
    if let kind { return ["command", "exec_command", "file", "permission", "apply_patch"].contains(kind) }
    return (object["tool_input"] as? [String: Any])?["command"] is String
}

private func approvalRequest(from object: [String: Any]) -> ApprovalRequest? {
    guard supportedPermission(object), let sessionValue = object["session_id"] as? String,
          let session = UUID(uuidString: sessionValue), let turnValue = object["turn_id"] as? String,
          let turn = UUID(uuidString: turnValue) else { return nil }
    let input = object["tool_input"] as? [String: Any]
    let details = ApprovalDetails(taskName: object["task_name"] as? String ?? object["title"] as? String,
                                  project: object["project"] as? String ?? object["cwd"] as? String,
                                  action: object["action"] as? String ?? object["tool_name"] as? String ?? object["kind"] as? String,
                                  command: object["command"] as? String ?? input?["command"] as? String,
                                  reason: object["reason"] as? String,
                                  longText: jsonText(input ?? object["tool_input"]))
    return ApprovalRequest(requestID: UUID(), sessionID: session, turnID: turn, details: details,
                           receivedAt: 0, expiresAt: 0, outcome: .pending)
}

private func update(_ request: ApprovalRequest, outcome: ApprovalDecision, in directory: URL) {
    let terminal = ApprovalRequest(requestID: request.requestID, sessionID: request.sessionID, turnID: request.turnID,
                                   details: request.details, receivedAt: request.receivedAt,
                                   expiresAt: request.expiresAt, outcome: outcome)
    guard let data = try? JSONEncoder().encode(terminal) else { return }
    try? data.write(to: ApprovalStore.requestURL(in: directory, id: request.id), options: .atomic)
}

private func decisionOutput(_ decision: ApprovalDecision) -> Data? {
    guard decision == .allowOnce || decision == .deny else { return nil }
    let value: [String: Any] = ["hookSpecificOutput": [
        "hookEventName": "PermissionRequest",
        "decision": ["behavior": decision == .allowOnce ? "allow" : "deny"]
    ]]
    return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func boundedRegularData(_ url: URL, limit: Int) -> Data? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          attributes[.type] as? FileAttributeType == .typeRegular,
          (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
          (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
          let file = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? file.close() }
    guard let bytes = try? file.read(upToCount: limit + 1), bytes.count <= limit else { return nil }
    return bytes
}

private func receipt(for request: ApprovalRequest, publishedAt: Double, in directory: URL) -> ApprovalReceiptRecord? {
    let deadlineUptime = ProcessInfo.processInfo.systemUptime + ApprovalTiming.connectionTimeout
    while ProcessInfo.processInfo.systemUptime < deadlineUptime {
        if let bytes = boundedRegularData(ApprovalStore.receiptURL(in: directory, id: request.id), limit: 4096),
           let value = try? JSONDecoder().decode(ApprovalReceiptRecord.self, from: bytes),
           value.requestID == request.id, value.receivedAt.isFinite,
           value.receivedAt >= publishedAt, value.receivedAt <= Date().timeIntervalSince1970,
           abs(value.expiresAt - (value.receivedAt + ApprovalTiming.handoffTimeout)) < 0.001 { return value }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return nil
}

private func awaitDecision(for request: ApprovalRequest, in directory: URL, waitBound: Double) -> ApprovalDecision {
    let coordinator = ApprovalCoordinator(requestID: request.id, expiresAt: request.expiresAt)
    let startedUptime = ProcessInfo.processInfo.systemUptime
    let hardDeadline = min(startedUptime + ApprovalTiming.handoffTimeout + 1, startedUptime + waitBound)
    let expiryUptime = startedUptime + ApprovalTiming.handoffTimeout
    while ProcessInfo.processInfo.systemUptime < hardDeadline {
        let now = Date().timeIntervalSince1970
        if let bytes = boundedRegularData(ApprovalStore.decisionURL(in: directory, id: request.id), limit: 4096),
           let record = try? JSONDecoder().decode(ApprovalDecisionRecord.self, from: bytes),
           record.decidedAt >= request.receivedAt, record.decidedAt <= now,
           let decision = coordinator.decide(requestID: record.requestID, decision: record.decision,
                                             at: record.decidedAt) {
            return decision
        }
        if ProcessInfo.processInfo.systemUptime >= expiryUptime,
           let expired = coordinator.expire(at: request.expiresAt) { return expired }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return coordinator.expire(at: request.expiresAt) ?? .noDecision
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
    guard ApprovalStore.publish(request, in: directory),
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
guard let published = approvalRequest(from: object),
      ApprovalStore.publish(published, in: directory),
      ProcessInfo.processInfo.systemUptime - receiptStartedUptime <= ApprovalTiming.connectionTimeout else { exit(0) }
guard let companionReceipt = receipt(for: published, publishedAt: receiptStarted, in: directory) else {
    update(published, outcome: .noDecision, in: directory)
    exit(0)
}
let request = ApprovalRequest(requestID: published.id, sessionID: published.sessionID, turnID: published.turnID,
                              details: published.details, receivedAt: companionReceipt.receivedAt,
                              expiresAt: companionReceipt.expiresAt, outcome: .pending)
let decision = awaitDecision(for: request, in: directory, waitBound: ApprovalTiming.helperWaitBound)
update(request, outcome: decision, in: directory)
if let output = decisionOutput(decision) { FileHandle.standardOutput.write(output) }
