import Darwin
import Foundation
import SteerCore

let arguments = CommandLine.arguments

func writeEvent(_ object: [String: Any], to directory: URL, installationID: String,
                environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
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
    HerdrPaneID.record(from: environment, into: &record)
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
                      helperRequestID: String? = nil,
                      environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
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
    for key in ["prompt_id", "tool_name", "tool_use_id"] {
        if let value = boundedClaudeString(object[key], limit: 256) { record[key] = value }
    }
    // A long prompt keeps its start, marked shortened, so the working row still has its text.
    if let prompt = ClaudeObservationReader.promptFallback(object["prompt"] as? String) {
        record["prompt"] = prompt.text
        if prompt.shortened { record[ClaudeObservationReader.promptShortenedKey] = true }
    }
    if let requestID = boundedClaudeString(object["approval_request_id"], limit: 256) {
        record["approval_request_id"] = requestID
    }
    // Set only by markDirectPermission, which bounds it: the path plus at most two previews of maximumPreview characters.
    if let details = object["approval_details"] as? [String: Any] { record["approval_details"] = details }
    if let input = object["tool_input"] as? [String: Any] {
        let kept = boundedClaudeToolInput(input)
        if !kept.isEmpty { record["tool_input"] = kept }
    }
    HerdrPaneID.record(from: environment, into: &record)
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
    let scalarKeys = Set(["command", "cmd", "file_path", "notebook_path", "path", "pattern", "url", "query"])
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

private let bridgeChunkBytes = 64 * 1024
// The helper has one foreground bridge operation. This PID is written before streaming and
// cleared after waitpid; the signal handler reads it only to terminate that operation's group.
nonisolated(unsafe) private var bridgeChildPID: pid_t = 0

private func writeAll(_ descriptor: Int32, base: UnsafeRawPointer, count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let written = write(descriptor, base.advanced(by: offset), count - offset)
        if written > 0 {
            offset += written
        } else if written < 0, errno == EINTR {
            continue
        } else {
            return false
        }
    }
    return true
}

private func execExistingStatusLine(_ existingCommand: String) -> Never {
    var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("sh"), strdup("-c"), strdup(existingCommand), nil]
    execv("/bin/sh", &arguments)
    _exit(71)
}

private func bridgeSignalHandler(_ signalNumber: Int32) -> Void {
    let child = bridgeChildPID
    if child > 0 {
        _ = kill(-child, SIGKILL)
        _ = kill(child, SIGKILL)
    }
    _exit(128 + signalNumber)
}

private func finishWithChildStatus(_ status: Int32) -> Never {
    if status & 0x7f == 0 {
        exit((status >> 8) & 0xff)
    }
    let signalNumber = status & 0x7f
    if signalNumber != 0x7f {
        signal(signalNumber, SIG_DFL)
        _ = kill(getpid(), signalNumber)
        _exit(128 + signalNumber)
    }
    _exit(70)
}

func runClaudeStatusLineBridge(usageDirectory: URL, existingCommand: String) -> Never {
    // Stream stdin through a pipe so forwarding remains byte-preserving without an unbounded
    // temporary file. Only a bounded prefix is retained for the optional usage projection.
    var bridgeInputPipe = [Int32](repeating: 0, count: 2)
    guard bridgeInputPipe.withUnsafeMutableBufferPointer({ buffer in
        pipe(buffer.baseAddress!)
    }) == 0 else {
        execExistingStatusLine(existingCommand)
    }
    var actions = posix_spawn_file_actions_t(bitPattern: 0)
    guard posix_spawn_file_actions_init(&actions) == 0,
          posix_spawn_file_actions_adddup2(&actions, bridgeInputPipe[0], STDIN_FILENO) == 0,
          posix_spawn_file_actions_addclose(&actions, bridgeInputPipe[0]) == 0,
          posix_spawn_file_actions_addclose(&actions, bridgeInputPipe[1]) == 0 else {
        close(bridgeInputPipe[0])
        close(bridgeInputPipe[1])
        execExistingStatusLine(existingCommand)
    }
    var attributes = posix_spawnattr_t(bitPattern: 0)
    guard posix_spawnattr_init(&attributes) == 0,
          posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
        posix_spawn_file_actions_destroy(&actions)
        close(bridgeInputPipe[0])
        close(bridgeInputPipe[1])
        execExistingStatusLine(existingCommand)
    }
    var childSignalMask = sigset_t()
    sigemptyset(&childSignalMask)
    guard posix_spawnattr_setsigmask(&attributes, &childSignalMask) == 0 else {
        posix_spawnattr_destroy(&attributes)
        posix_spawn_file_actions_destroy(&actions)
        close(bridgeInputPipe[0])
        close(bridgeInputPipe[1])
        execExistingStatusLine(existingCommand)
    }
    var blockedSignals = sigset_t()
    sigemptyset(&blockedSignals)
    sigaddset(&blockedSignals, SIGTERM)
    sigaddset(&blockedSignals, SIGINT)
    sigprocmask(SIG_BLOCK, &blockedSignals, nil)
    var child: pid_t = 0
    var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("sh"), strdup("-c"), strdup(existingCommand), nil]
    let spawnResult = arguments.withUnsafeMutableBufferPointer { argumentBuffer in
        posix_spawn(&child, "/bin/sh", &actions, &attributes, argumentBuffer.baseAddress!, environ)
    }
    posix_spawnattr_destroy(&attributes)
    posix_spawn_file_actions_destroy(&actions)
    guard spawnResult == 0 else {
        sigprocmask(SIG_UNBLOCK, &blockedSignals, nil)
        close(bridgeInputPipe[0])
        close(bridgeInputPipe[1])
        execExistingStatusLine(existingCommand)
    }
    close(bridgeInputPipe[0])
    bridgeChildPID = child
    signal(SIGTERM, bridgeSignalHandler)
    signal(SIGINT, bridgeSignalHandler)
    // A command may finish without reading stdin. Treat its closed pipe as an ordinary
    // forwarding short read so the helper can return the command's real exit status.
    signal(SIGPIPE, SIG_IGN)
    sigprocmask(SIG_UNBLOCK, &blockedSignals, nil)

    var inputSize = 0
    var captured = Data()
    captured.reserveCapacity(ClaudeUsageReader.maximumRecordBytes + 1)
    var buffer = [UInt8](repeating: 0, count: bridgeChunkBytes)
    var captureCompleted = true
    while true {
        let readCount = buffer.withUnsafeMutableBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return -1 }
            return read(STDIN_FILENO, base, bytes.count)
        }
        if readCount == 0 { break }
        if readCount < 0 {
            if errno == EINTR { continue }
            captureCompleted = false
            break
        }
        guard inputSize <= Int.max - readCount,
              buffer.withUnsafeBytes({ bytes in
                  guard let base = bytes.baseAddress else { return false }
                  return writeAll(bridgeInputPipe[1], base: base, count: readCount)
              }) else {
            captureCompleted = false
            break
        }
        inputSize += readCount
        if captured.count <= ClaudeUsageReader.maximumRecordBytes {
            let remaining = ClaudeUsageReader.maximumRecordBytes + 1 - captured.count
            captured.append(contentsOf: buffer.prefix(min(remaining, readCount)))
        }
    }
    close(bridgeInputPipe[1])
    if captureCompleted, inputSize <= ClaudeUsageReader.maximumRecordBytes {
        _ = ClaudeUsageReader.record(captured, to: usageDirectory)
    }

    var status: Int32 = 0
    while true {
        let result = waitpid(child, &status, 0)
        if result >= 0 { break }
        if errno != EINTR {
            bridgeChildPID = 0
            _exit(70)
        }
    }
    bridgeChildPID = 0
    finishWithChildStatus(status)
}

private func update(_ request: ApprovalRequest, outcome: ApprovalDecision, in directory: URL) {
    let terminal = ApprovalRequest(requestID: request.requestID, sessionID: request.sessionID, turnID: request.turnID,
                                   details: request.details, receivedAt: request.receivedAt,
                                   expiresAt: request.expiresAt, outcome: outcome)
    guard let data = try? JSONEncoder().encode(terminal) else { return }
    try? data.write(to: ApprovalStore.requestURL(in: directory, id: request.id), options: .atomic)
}

/// Marks a Claude `PermissionRequest` Steer may decide: a fresh request token and, for a file request, the
/// validated display details. Returns nil, leaving the object unchanged, for anything else, so only an exact,
/// proven request shape waits for Steer and every other request stays in Claude's own dialog.
func markDirectPermission(_ object: inout [String: Any]) -> String? {
    // Only this function sets these keys; a value arriving on stdin is never trusted or kept.
    object.removeValue(forKey: "approval_details")
    object.removeValue(forKey: "approval_request_id")
    guard object["hook_event_name"] as? String == "PermissionRequest", let tool = object["tool_name"] as? String else { return nil }
    let input = object["tool_input"] as? [String: Any] ?? [:]
    guard ClaudeDirectApproval.accepts(toolName: tool, toolInput: input) else { return nil }
    if tool != "Bash" {
        guard let details = ClaudeDirectApproval.details(toolName: tool, toolInput: input),
              let data = try? JSONEncoder().encode(details),
              let encoded = try? JSONSerialization.jsonObject(with: data) else { return nil }
        object["approval_details"] = encoded
    }
    let requestID = UUID().uuidString
    object["approval_request_id"] = requestID
    return requestID
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
    let paneDirectory = directory.appendingPathComponent("herdr", isDirectory: true)
    let paneEvent: [String: Any] = ["hook_event_name": "SessionStart", "session_id": session.uuidString]
    let paneEnvironment = ["HERDR_PANE_ID": "w1:p1", "HERDR_SOCKET_PATH": "/tmp/herdr.sock"]
    guard writeEvent(paneEvent, to: paneDirectory, installationID: "self-test", environment: paneEnvironment),
          writeClaudeEvent(paneEvent, to: paneDirectory, installationID: UUID().uuidString,
                           environment: paneEnvironment),
          writeEvent(paneEvent, to: paneDirectory, installationID: "self-test",
                     environment: ["HERDR_PANE_ID": "w1:p1\n", "HERDR_SOCKET_PATH": "/tmp/herdr.sock"]),
          writeEvent(paneEvent, to: paneDirectory, installationID: "self-test", environment: [:]),
          let paneRecords = (try? FileManager.default.contentsOfDirectory(at: paneDirectory, includingPropertiesForKeys: nil))?
            .compactMap({ try? Data(contentsOf: $0) })
            .compactMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
          paneRecords.count == 4,
          paneRecords.filter({ HerdrPaneID.recorded(in: $0) == "w1:p1" }).count == 2,
          paneRecords.filter({ $0[HerdrPaneID.recordKey] != nil }).count == 2,
          paneRecords.filter({ HerdrSocketPath.recorded(in: $0) == "/tmp/herdr.sock" }).count == 2,
          paneRecords.filter({ $0[HerdrSocketPath.recordKey] != nil }).count == 2 else { return 1 }
    try? FileManager.default.removeItem(at: paneDirectory)
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
    // A file request with the proven shape waits for Steer and keeps only bounded display details; any
    // other shape, or an unproven tool, is left to Claude's own dialog.
    let fileDirectory = directory.appendingPathComponent("file-approval", isDirectory: true)
    var edit: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": session.uuidString,
                               "prompt_id": "prompt-1", "tool_name": "Edit",
                               "tool_input": ["file_path": "/tmp/target.txt", "old_string": "alpha", "new_string": "beta",
                                              "replace_all": false]]
    var extraKey = edit
    extraKey["tool_input"] = ["file_path": "/tmp/target.txt", "old_string": "a", "new_string": "b", "unproven": true]
    var grep: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": session.uuidString,
                               "tool_name": "Grep", "tool_input": ["pattern": "x", "path": "/tmp"]]
    var bash: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": session.uuidString,
                               "tool_name": "Bash", "tool_input": ["command": "touch marker"]]
    var forged: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": session.uuidString, "tool_name": "Grep",
                                 "tool_input": ["pattern": "x"], "approval_details": ["action": "Edit file", "command": "/etc/hosts"],
                                 "approval_request_id": "forged"]
    guard markDirectPermission(&edit) != nil, markDirectPermission(&extraKey) == nil, extraKey["approval_details"] == nil,
          markDirectPermission(&grep) == nil, markDirectPermission(&bash) != nil, bash["approval_details"] == nil,
          markDirectPermission(&forged) == nil, forged["approval_details"] == nil, forged["approval_request_id"] == nil,
          { var fetch: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": session.uuidString,
                                        "tool_name": "WebFetch", "tool_input": ["url": "https://example.com/", "prompt": "title"]]
            var plan: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": session.uuidString,
                                       "tool_name": "ExitPlanMode", "tool_input": ["plan": "x", "planFilePath": "/tmp/p.md"]]
            return markDirectPermission(&fetch) != nil && (fetch["approval_details"] as? [String: Any])?["command_label"] as? String == "url"
                && markDirectPermission(&plan) == nil }(),
          writeClaudeEvent(edit, to: fileDirectory, installationID: UUID().uuidString),
          let fileRecord = (try? FileManager.default.contentsOfDirectory(at: fileDirectory, includingPropertiesForKeys: nil))?
            .compactMap({ try? Data(contentsOf: $0) })
            .compactMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }).first,
          fileRecord["approval_request_id"] as? String == edit["approval_request_id"] as? String,
          let details = fileRecord["approval_details"] as? [String: Any],
          details["action"] as? String == "Edit file", details["command"] as? String == "/tmp/target.txt",
          (fileRecord["tool_input"] as? [String: String]) == ["file_path": "/tmp/target.txt"] else { return 1 }
    let promptDirectory = directory.appendingPathComponent("claude-prompt", isDirectory: true)
    let longPrompt = String(repeating: "Explain why the queue keeps this order. ", count: 12)
    guard writeClaudeEvent(["hook_event_name": "UserPromptSubmit", "session_id": session.uuidString,
                            "prompt_id": "prompt-2", "prompt": longPrompt],
                           to: promptDirectory, installationID: UUID().uuidString),
          let promptRecord = (try? FileManager.default.contentsOfDirectory(at: promptDirectory, includingPropertiesForKeys: nil))?
            .compactMap({ try? Data(contentsOf: $0) })
            .compactMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }).first,
          let shortened = ClaudeObservationReader.promptFallback(longPrompt), shortened.shortened,
          promptRecord["prompt"] as? String == shortened.text,
          promptRecord[ClaudeObservationReader.promptShortenedKey] as? Bool == true else { return 1 }
    return 0
}

if arguments.contains("--self-test") { exit(selfTest()) }
if arguments.dropFirst().first == claudeTitleGeneratorMarker { runClaudeTitleGenerator(arguments) }
if let bridgeIndex = arguments.firstIndex(of: ClaudeStatusLineBridge.marker),
   arguments.indices.contains(bridgeIndex + 1), arguments[bridgeIndex + 1] == "--usage-dir",
   arguments.indices.contains(bridgeIndex + 3), arguments[bridgeIndex + 2].isEmpty == false,
   arguments[bridgeIndex + 3] == "--existing-command", arguments.indices.contains(bridgeIndex + 4) {
    runClaudeStatusLineBridge(usageDirectory: URL(fileURLWithPath: arguments[bridgeIndex + 2], isDirectory: true),
                              existingCommand: arguments[bridgeIndex + 4])
}
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
    guard var object = input else { exit(0) }
    let isQuestion = arguments.contains("--question-helper") && object["hook_event_name"] as? String == "PreToolUse"
        && object["tool_name"] as? String == "AskUserQuestion"
    let questionRequestID = isQuestion ? UUID().uuidString : nil
    let publishedAt = Date().timeIntervalSince1970
    let approvalRequestID = markDirectPermission(&object)
    guard writeClaudeEvent(object, to: directory, installationID: installationID,
                           helperRequestID: questionRequestID) else { exit(0) }
    if isQuestion,
       let session = boundedClaudeString(object["session_id"], limit: 256),
       let promptID = boundedClaudeString(object["prompt_id"], limit: 256),
       let toolUseID = boundedClaudeString(object["tool_use_id"], limit: 256),
       let toolInput = object["tool_input"] as? [String: Any],
       let parsed = QuestionPrompt.parseCall(toolInput: toolInput), parsed.count == 1,
       let sourceScope,
       let questionRequestID {
        let publishedAt = Date().timeIntervalSince1970
        let question = ClaudeQuestionRequest(requestID: questionRequestID, installationID: installationID,
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
            let delivery = ClaudeQuestionDelivery(
                requestID: answer.requestID, installationID: answer.installationID,
                sourceScope: answer.sourceScope, eventDirectory: answer.eventDirectory,
                sessionID: answer.sessionID, promptID: answer.promptID,
                toolUseID: answer.toolUseID, answerDecidedAt: answer.decidedAt,
                deliveredAt: Date().timeIntervalSince1970)
            _ = ClaudeQuestionStore.publish(delivery, in: directory)
            ClaudeQuestionStore.removeAnswer(for: answer.requestID, in: directory)
        }
        ClaudeQuestionStore.removeLiveness(for: question.requestID, in: directory)
    }
    if arguments.contains("--terminal-title"),
       let event = object["hook_event_name"] as? String,
       event == "SessionStart" || event == "SessionEnd",
       let session = object["session_id"] as? String,
       let output = terminalSequence(for: session, reset: event == "SessionEnd") {
        FileHandle.standardOutput.write(output)
    }
    if let output = claudeSessionTitleOutput(object, eventsDirectory: directory) {
        FileHandle.standardOutput.write(output)
    }
    if let approvalRequestID {
        let live = ClaudeApprovalLiveness(requestID: approvalRequestID, publishedAt: publishedAt,
                                          heartbeatAt: Date().timeIntervalSince1970)
        if ClaudeApprovalStore.publish(live, in: directory),
           let receipt = ClaudeApprovalHelper.awaitReceipt(for: approvalRequestID, publishedAt: publishedAt,
                                                           in: directory, liveness: live),
           let decision = ClaudeApprovalHelper.awaitDecisionRecord(for: approvalRequestID, receipt: receipt,
                                                                   in: directory, liveness: live),
           let output = ClaudeApprovalHelper.hookOutput(for: decision.decision) {
            FileHandle.standardOutput.write(output)
            _ = ClaudeApprovalStore.publish(ClaudeApprovalDelivery(requestID: decision.requestID,
                                                                   decision: decision.decision,
                                                                   decidedAt: decision.decidedAt,
                                                                   deliveredAt: Date().timeIntervalSince1970),
                                            in: directory)
        }
        ClaudeApprovalStore.removeLiveness(for: approvalRequestID, in: directory)
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
