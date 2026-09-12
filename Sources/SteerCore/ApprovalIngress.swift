import Foundation

/// Turns a Codex PermissionRequest hook payload into one identity-bound request.
/// Only fields Codex supplied are carried; nothing is invented for missing context.
public enum ApprovalRequestParser {
    static let supportedKinds: Set<String> = ["bash", "command", "exec_command", "file", "permission", "apply_patch"]

    public static func request(from object: [String: Any]) -> ApprovalRequest? {
        guard isSupported(object), let sessionValue = object["session_id"] as? String,
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

    /// Uncovered approval types return false so they stay in Codex's normal flow.
    static func isSupported(_ object: [String: Any]) -> Bool {
        let kind = (object["permission_type"] as? String ?? object["kind"] as? String ?? object["tool_name"] as? String)?.lowercased()
        if let kind { return supportedKinds.contains(kind) }
        return (object["tool_input"] as? [String: Any])?["command"] is String
    }

    private static func jsonText(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let value = value as? String { return value }
        guard JSONSerialization.isValidJSONObject(value),
              let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}

/// Decides when an actionable request must be released to Codex with no decision.
public enum ApprovalHandoff {
    /// Desktop requests always hand back: their decision transport and handoff policy are
    /// unproven, so Codex keeps its native prompt. CLI requests stay actionable only while
    /// the originating Ghostty pane is verified away; a check in flight waits for its result.
    public static func mustHandBack(source: AttentionSource, paneFocus: CompletionFocus) -> Bool {
        switch source {
        case .desktop: return true
        case .cli: return paneFocus != .away && paneFocus != .checking
        }
    }
}
