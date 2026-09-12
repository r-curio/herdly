import Foundation

/// Rollout line timestamps (`2026-09-12T04:23:07.201Z`), with or without fractional seconds.
public enum RolloutTimestamp {
    public static func parse(_ value: String) -> Double? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value))?.timeIntervalSince1970
    }
}

/// One handed-back request to look for in its session's rollout. Nothing is matched without an exact turn and command.
public struct ApprovalResolutionProbe: Equatable, Sendable {
    public let requestID: UUID
    public let turn: UUID
    public let command: String?
    /// Companion receipt time; outputs recorded before it belong to an earlier invocation.
    public let notBefore: Double

    public init(requestID: UUID, turn: UUID, command: String?, notBefore: Double) {
        self.requestID = requestID; self.turn = turn; self.command = command; self.notBefore = notBefore
    }
}

public enum ApprovalResolutionKind: String, Codable, Equatable, Sendable {
    /// The command produced a completed result: allowed natively or by another policy.
    case executed
    /// Codex recorded a rejection for the command.
    case rejected
    /// The user interrupted the turn while the prompt was open.
    case interrupted
    /// A terminal output exists but its wording is not one Steer recognizes; the prompt is no longer pending.
    case unclassified
}

/// Evidence that Codex resolved one handed-back request. Recorded, never inferred from a hidden prompt.
public struct ApprovalResolution: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let kind: ApprovalResolutionKind
    public let callID: String
    public let observedAt: Double

    public init(requestID: UUID, kind: ApprovalResolutionKind, callID: String, observedAt: Double) {
        self.requestID = requestID; self.kind = kind; self.callID = callID; self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id", kind, callID = "call_id", observedAt = "observed_at"
    }
}

/// Reads native resolution evidence from a session rollout. A request is matched to the earliest
/// exec call in its exact turn with its exact command whose terminal output was recorded after the
/// companion receipt; each call answers one request. Malformed or partial lines are skipped, which
/// can only delay evidence, never invent it.
public enum ApprovalResolutionReader {
    private struct Call { let id: String; let turn: UUID; let command: String; let at: Double }
    private struct FollowUp { let id: String; let turn: UUID; let cell: String; let at: Double }
    private struct Output { let text: String; let at: Double }
    private enum Terminal { case running(cell: String?), resolved(ApprovalResolutionKind) }

    public static func resolutions(in data: Data, session: UUID, probes: [ApprovalResolutionProbe]) -> [ApprovalResolution] {
        guard !probes.isEmpty, data.count <= 32 * 1024 * 1024 else { return [] }
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if data.last != 10 { lines = lines.dropLast() }
        var calls: [Call] = []
        var followUps: [FollowUp] = []
        var outputs: [String: Output] = [:]
        for (index, line) in lines.enumerated() {
            guard line.count <= 1024 * 1024, !line.isEmpty,
                  let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = event["payload"] as? [String: Any] else { if index == 0 { return [] } else { continue } }
            if index == 0 {
                guard event["type"] as? String == "session_meta",
                      (payload["id"] as? String).flatMap(UUID.init(uuidString:)) == session else { return [] }
                continue
            }
            guard event["type"] as? String == "response_item",
                  let at = (event["timestamp"] as? String).flatMap(RolloutTimestamp.parse) else { continue }
            let kind = payload["type"] as? String
            let callID = payload["call_id"] as? String
            if kind == "custom_tool_call_output" || kind == "function_call_output" {
                if let callID, let text = outputText(payload["output"]) { outputs[callID] = Output(text: text, at: at) }
                continue
            }
            guard kind == "custom_tool_call" || kind == "function_call", let callID,
                  let turn = ((payload["internal_chat_message_metadata_passthrough"] as? [String: Any])?["turn_id"] as? String)
                    .flatMap(UUID.init(uuidString:)) else { continue }
            let name = payload["name"] as? String ?? ""
            if kind == "custom_tool_call", name == "exec", let input = payload["input"] as? String {
                // One exec script can await several commands; each is registered under the same call.
                for command in commands(inJavaScript: input) { calls.append(Call(id: callID, turn: turn, command: command, at: at)) }
            } else if kind == "function_call", let arguments = (payload["arguments"] as? String).flatMap(jsonObject) {
                if ["wait", "write_stdin"].contains(name), let cell = cellID(arguments["cell_id"]) {
                    followUps.append(FollowUp(id: callID, turn: turn, cell: cell, at: at))
                } else if let command = command(inArguments: arguments) {
                    calls.append(Call(id: callID, turn: turn, command: command, at: at))
                }
            }
        }
        calls.sort { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
        followUps.sort { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
        var consumed: Set<String> = []
        var found: [ApprovalResolution] = []
        for probe in probes.sorted(by: { $0.notBefore == $1.notBefore ? $0.requestID.uuidString < $1.requestID.uuidString : $0.notBefore < $1.notBefore }) {
            guard let command = probe.command else { continue }
            for call in calls where call.turn == probe.turn && call.command == command && !consumed.contains(call.id + "\u{0}" + command) {
                guard let (terminalCall, output, kind) = terminal(for: call, outputs: outputs, followUps: followUps),
                      output.at >= probe.notBefore - 1 else { continue }
                consumed.insert(call.id + "\u{0}" + command)
                found.append(ApprovalResolution(requestID: probe.requestID, kind: kind, callID: terminalCall, observedAt: output.at))
                break
            }
        }
        return found
    }

    /// Follows a yielded exec through its later `wait`/`write_stdin` calls to the last recorded output.
    private static func terminal(for call: Call, outputs: [String: Output], followUps: [FollowUp]) -> (String, Output, ApprovalResolutionKind)? {
        guard let output = outputs[call.id] else { return nil }
        switch classify(output.text) {
        case let .resolved(kind): return (call.id, output, kind)
        case let .running(cell):
            guard let cell else { return nil }
            var latest: (String, Output, ApprovalResolutionKind)?
            for follow in followUps where follow.turn == call.turn && follow.cell == cell && follow.at >= output.at {
                guard let later = outputs[follow.id] else { continue }
                switch classify(later.text) {
                case let .resolved(kind): latest = (follow.id, later, kind)
                case .running: latest = nil
                }
            }
            return latest
        }
    }

    /// Classification keys on the runtime's own wrapper text at the start of the output, never on
    /// command output, which can contain any wording.
    private static func classify(_ text: String) -> Terminal {
        let head = text.prefix(200)
        if head.hasPrefix("Script running") {
            let cell = head.range(of: "cell ID ").map { head[$0.upperBound...].prefix { $0.isNumber || $0.isLetter || $0 == "-" } }
            return .running(cell: cell.map(String.init))
        }
        if head.hasPrefix("Script completed") || head.hasPrefix("Chunk ID") || head.contains("Process exited with code") { return .resolved(.executed) }
        if head.hasPrefix("aborted by user") { return .resolved(.interrupted) }
        if head.hasPrefix("Script failed") || head.hasPrefix("exec_command failed") || head.hasPrefix("Script error") {
            return .resolved(text.contains("Rejected(") ? .rejected : .unclassified)
        }
        return .resolved(.unclassified)
    }

    private static func outputText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let parts = value as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined()
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    private static func cellID(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func command(inArguments arguments: [String: Any]) -> String? {
        if let text = arguments["cmd"] as? String { return text }
        if let text = arguments["command"] as? String { return text }
        if let parts = arguments["command"] as? [String] { return parts.joined(separator: " ") }
        return nil
    }

    /// Every `cmd:"..."` or `"cmd":"..."` inside the exec tool's JavaScript; each value is a JSON string literal.
    private static func commands(inJavaScript input: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|[\s{,])"?cmd"?\s*:\s*("(?:[^"\\]|\\.)*")"#) else { return [] }
        return regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: input) else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(input[range].utf8), options: [.fragmentsAllowed]) as? String
        }
    }
}

/// The companion may write a decision only for a live, actionable, receipted CLI request.
public enum ApprovalDecisionPolicy {
    public static func accepts(_ request: AttentionRequest, decision: ApprovalDecision, now: Double) -> Bool {
        decision.isUserDecision && request.source == .cli && request.state == .actionable && now < request.expiresAt
    }
}
