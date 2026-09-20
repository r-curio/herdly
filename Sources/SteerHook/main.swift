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
    if let prompt = object["prompt"] as? String { record["prompt"] = prompt }
    if let name = object["tool_name"] as? String { record["tool_name"] = name }
    if let useID = object["tool_use_id"] as? String { record["tool_use_id"] = useID }
    if let input = object["tool_input"] as? [String: Any] {
        let kept = ["command", "cmd", "file_path", "path", "pattern"].reduce(into: [String: String]()) { result, key in
            if let value = input[key] as? String { result[key] = value }
        }
        if !kept.isEmpty { record["tool_input"] = kept }
    }
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

func writeClaudeEvent(_ object: [String: Any], to directory: URL, installationID: String,
                      helperRequestID: String? = nil) -> Bool {
    guard let event = boundedClaudeString(object["hook_event_name"], limit: 256),
          let session = boundedClaudeString(object["session_id"], limit: 256),
          boundedClaudeString(installationID, limit: 256) != nil else { return false }
    let now = Date()
    var record: [String: Any] = [
        "hook_event_name": event, "session_id": session, "source": ClaudeSetupRequirements.helperSource,
        "installation_id": installationID, "received_at": ISO8601DateFormatter().string(from: now),
        "captured_at": now.timeIntervalSince1970
    ]
    if event == "SessionStart", let source = boundedClaudeString(object["source"], limit: 256) {
        record["session_start_source"] = source
    }
    if let helperRequestID = boundedClaudeString(helperRequestID, limit: 256) {
        record["helper_request_id"] = helperRequestID
    }
    for key in ["prompt_id", "prompt", "tool_name", "tool_use_id"] {
        let limit = key == "prompt" ? QuestionPrompt.maximumQuestion : 256
        if let value = boundedClaudeString(object[key], limit: limit, allowNewline: key == "prompt") {
            record[key] = value
        }
    }
    if let input = object["tool_input"] as? [String: Any] {
        let kept = boundedClaudeToolInput(input)
        if !kept.isEmpty { record["tool_input"] = kept }
    }
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

private func boundedClaudeString(_ value: Any?, limit: Int = 4096, allowNewline: Bool = false) -> String? {
    guard let value = value as? String, !value.isEmpty, value.utf8.count <= limit,
          !value.contains(where: { (!allowNewline && $0.isNewline) || $0 == "\u{1b}" || $0 == "\u{7}" || $0 == "\u{0}" }) else { return nil }
    return value
}

private func boundedClaudeToolInput(_ input: [String: Any]) -> [String: Any] {
    let scalarKeys = Set(["command", "cmd", "file_path", "path", "pattern", "url"])
    var result: [String: Any] = [:]
    for key in scalarKeys {
        if let value = boundedClaudeString(input[key], allowNewline: true) { result[key] = value }
    }
    if let questions = input["questions"] as? [[String: Any]], questions.count <= QuestionPrompt.maximumQuestions {
        let kept = questions.compactMap { question -> [String: Any]? in
            guard let text = boundedClaudeString(question["question"], limit: QuestionPrompt.maximumQuestion) else { return nil }
            var value: [String: Any] = ["question": text]
            if let header = boundedClaudeString(question["header"], limit: QuestionPrompt.maximumHeader) { value["header"] = header }
            if let multiSelect = question["multiSelect"] as? Bool { value["multiSelect"] = multiSelect }
            if let isOther = question["isOther"] as? Bool { value["isOther"] = isOther }
            if let options = question["options"] as? [[String: Any]], options.count <= QuestionPrompt.maximumOptions {
                let labels = options.compactMap { boundedClaudeString($0["label"], limit: QuestionPrompt.maximumLabel) }
                guard labels.count == options.count else { return nil }
                value["options"] = labels.map { ["label": $0] }
            } else if question["options"] != nil {
                return nil
            }
            return value
        }
        if kept.count == questions.count { result["questions"] = kept }
    }
    if let ids = input["tool_use_ids"] as? [String], ids.count <= 64 {
        let kept = ids.compactMap { boundedClaudeString($0, limit: 256) }
        if !kept.isEmpty { result["tool_use_ids"] = kept }
    }
    if let uses = input["tool_uses"] as? [[String: Any]], uses.count <= 64 {
        let kept = uses.compactMap { use -> [String: Any]? in
            guard let id = boundedClaudeString(use["tool_use_id"], limit: 256) else { return nil }
            return ["tool_use_id": id]
        }
        if !kept.isEmpty { result["tool_uses"] = kept }
    }
    return result
}

func terminalSequence(for session: String, reset: Bool = false) -> Data? {
    let sequence = reset ? "\u{1b}]2;\u{7}" : "\u{1b}]2;\(ClaudeSetupRequirements.titlePrefix)\(session)\u{7}"
    return try? JSONSerialization.data(withJSONObject: ["terminalSequence": sequence], options: [.sortedKeys])
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
    let tool: [String: Any] = ["hook_event_name": "PreToolUse", "session_id": session.uuidString,
                               "turn_id": turn.uuidString, "tool_name": "Bash", "tool_use_id": "tool-1",
                               "tool_input": ["command": "swift test", "ignored": ["large", "value"]]]
    guard writeEvent(tool, to: directory, installationID: "self-test"),
          let records = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap({ try? Data(contentsOf: $0) }).compactMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
          let stored = records.first(where: { $0["tool_use_id"] as? String == "tool-1" }),
          (stored["tool_input"] as? [String: String]) == ["command": "swift test"], stored["tool_response"] == nil else { return 1 }
    let request = ApprovalRequest(requestID: UUID(), sessionID: session, turnID: turn,
                                  details: ApprovalDetails(command: "touch marker"), receivedAt: 100)
    let bashPayload: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": session.uuidString,
                                      "turn_id": turn.uuidString, "tool_name": "Bash",
                                      "tool_input": ["command": "touch marker"]]
    guard ApprovalStore.publish(request, in: directory),
          ApprovalRequestParser.request(from: bashPayload) != nil,
          ApprovalStore.publish(ApprovalDecisionRecord(requestID: request.id, decision: .allowOnce, decidedAt: 101), in: directory),
          ApprovalCoordinator(requestID: request.id, expiresAt: 130).decide(requestID: request.id, decision: .allowOnce, at: 101) == .allowOnce else { return 1 }
    let claude: [String: Any] = ["hook_event_name": "SessionStart", "session_id": session.uuidString,
                                 "source": "startup", "prompt_id": "prompt-1", "tool_name": "Bash",
                                 "tool_use_id": "claude-tool-1", "tool_input": ["command": "swift test", "secret": "drop"]]
    guard writeClaudeEvent(claude, to: directory, installationID: UUID().uuidString),
          let claudeRecord = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .compactMap({ try? Data(contentsOf: $0) })
            .compactMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            .first(where: { $0["source"] as? String == ClaudeSetupRequirements.helperSource }),
          claudeRecord["hook_event_name"] as? String == "SessionStart",
          claudeRecord["session_start_source"] as? String == "startup",
          claudeRecord["prompt_id"] as? String == "prompt-1",
          claudeRecord["tool_use_id"] as? String == "claude-tool-1",
          (claudeRecord["tool_input"] as? [String: String]) == ["command": "swift test"],
          terminalSequence(for: session.uuidString).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: String] })?["terminalSequence"]
            == "\u{1b}]2;\(ClaudeSetupRequirements.titlePrefix)\(session.uuidString)\u{7}",
          terminalSequence(for: session.uuidString, reset: true).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: String] })?["terminalSequence"]
            == "\u{1b}]2;\u{7}" else { return 1 }
    return 0
}

if arguments.contains("--self-test") { exit(selfTest()) }
if let agentIndex = arguments.firstIndex(of: "--agent"), arguments.indices.contains(agentIndex + 1),
   arguments[agentIndex + 1] == "claude" {
    guard let index = arguments.firstIndex(of: "--events-dir"), arguments.indices.contains(index + 1),
          let installationIndex = arguments.firstIndex(of: "--installation-id"), arguments.indices.contains(installationIndex + 1),
          UUID(uuidString: arguments[installationIndex + 1]) != nil else { exit(0) }
    let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    let installationID = arguments[installationIndex + 1]
    let sourceScope: String? = arguments.firstIndex(of: "--source-scope").flatMap { sourceIndex in
        guard arguments.indices.contains(sourceIndex + 1) else { return nil }
        return URL(fileURLWithPath: arguments[sourceIndex + 1]).standardizedFileURL.path
    }
    let input = (try? FileHandle.standardInput.read(upToCount: 64 * 1024)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    guard let object = input else { exit(0) }
    let isQuestion = arguments.contains("--question-helper") && object["hook_event_name"] as? String == "PreToolUse"
        && object["tool_name"] as? String == "AskUserQuestion"
    let requestID = isQuestion ? UUID().uuidString : nil
    guard writeClaudeEvent(object, to: directory, installationID: installationID, helperRequestID: requestID) else { exit(0) }
    if isQuestion,
       let session = boundedClaudeString(object["session_id"], limit: 256),
       let promptID = boundedClaudeString(object["prompt_id"], limit: 256),
       let toolUseID = boundedClaudeString(object["tool_use_id"], limit: 256),
       let toolInput = object["tool_input"] as? [String: Any],
       let parsed = QuestionPrompt.parseCall(toolInput: toolInput), parsed.count == 1,
       let sourceScope,
       let requestID {
        let publishedAt = Date().timeIntervalSince1970
        let question = ClaudeQuestionRequest(requestID: requestID, installationID: installationID,
                                             sourceScope: sourceScope,
                                             eventDirectory: directory.standardizedFileURL.path,
                                             sessionID: session, promptID: promptID, toolUseID: toolUseID,
                                             publishedAt: publishedAt,
                                             expiresAt: publishedAt + ClaudeQuestionTiming.answerTimeout,
                                             prompts: parsed.prompts)
        if ClaudeQuestionStore.publish(question, in: directory),
           let answer = ClaudeQuestionHelper.awaitAnswer(for: question, in: directory),
           let output = ClaudeQuestionAnswerPolicy.hookOutput(toolInput: toolInput, request: question, answer: answer) {
            FileHandle.standardOutput.write(output)
        }
    }
    if arguments.contains("--terminal-title"),
       let event = object["hook_event_name"] as? String,
       event == "SessionStart" || event == "SessionEnd",
       let session = object["session_id"] as? String,
       let output = terminalSequence(for: session, reset: event == "SessionEnd") {
        FileHandle.standardOutput.write(output)
    }
    exit(0)
}
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
