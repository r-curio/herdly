import Foundation

/// The text of a Codex tool call as rollouts record it, shared by `ApprovalResolutionReader` and
/// `CodexSubagentReader`.
enum CodexToolCallText {
    /// A function call's `arguments`, a JSON object encoded as a string; nil for anything else.
    static func jsonObject(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    /// The shell command in a function call's arguments: `cmd`, or `command` as text or argv.
    static func command(inArguments arguments: [String: Any]) -> String? {
        if let text = arguments["cmd"] as? String { return text }
        if let text = arguments["command"] as? String { return text }
        if let parts = arguments["command"] as? [String] { return parts.joined(separator: " ") }
        return nil
    }

    /// Every `cmd:"..."` or `"cmd":"..."` inside the exec tool's JavaScript; each value is a JSON string literal.
    static func commands(inJavaScript input: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|[\s{,])"?cmd"?\s*:\s*("(?:[^"\\]|\\.)*")"#) else { return [] }
        return regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: input) else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(input[range].utf8), options: [.fragmentsAllowed]) as? String
        }
    }
}

/// Rules for a rollout's `session_meta` payload shared by every reader of child rollouts.
enum CodexRolloutHeader {
    /// The thread that owns a child rollout (a spawned agent or a guardian review): the first of
    /// `parent_thread_id`, the spawn's `source.subagent.thread_spawn.parent_thread_id`, and
    /// `forked_from_id`. Nil when none is a UUID, when two disagree, or when it names the rollout
    /// itself, so a header that cannot say whose it is credits nothing to anyone.
    static func parent(in payload: [String: Any]) -> UUID? {
        let spawn = ((payload["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
        let named = [payload["parent_thread_id"], spawn?["parent_thread_id"], payload["forked_from_id"]]
            .compactMap { ($0 as? String).flatMap(UUID.init(uuidString:)) }
        guard let parent = named.first, named.allSatisfy({ $0 == parent }),
              (payload["id"] as? String).flatMap(UUID.init(uuidString:)) != parent else { return nil }
        return parent
    }
}
