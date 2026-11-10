import Foundation

/// Running Codex subagents read from their own rollouts (#396), for the working row of the session
/// that spawned them. Codex CLI and desktop write each spawned agent as a rollout whose first line is
/// a `session_meta` with `source: {"subagent":{"thread_spawn":{…}}}`, `parent_thread_id`, the
/// agent's `agent_nickname` and `agent_path`, and a start `timestamp`. A spawned agent forks its
/// parent's history: the parent's header and lines follow the child's header, and the child's own
/// history begins at `subagent_history_start_ordinal` (each line carries an `ordinal`).
///
/// Presentation data only. A subagent rollout is never a session (`SessionDiscovery` excludes it),
/// and nothing here orders the queue, counts as work, or acknowledges anything. See
/// docs/session-discovery.md, "Subagent activity".
public enum CodexSubagentReader {
    /// Nested spawns are followed up to this many parents to reach the root session.
    static let maximumDepth = 8
    /// Subagent rollouts whose tail is read per call, newest written first: as many as
    /// `SessionDiscovery` reads per scan, so the two readers cost the same order of bytes.
    static let maximumTails = SessionDiscovery.maximumFiles

    /// What one subagent rollout's first line says about it.
    struct Head: Equatable {
        let id: UUID
        let parent: UUID
        /// The tree's root thread (`session_id`), when the header names one.
        let root: UUID?
        /// How deep the spawn is (`thread_spawn.depth`), when recorded.
        let depth: Int?
        /// The display name before `SubagentActivity.names` numbers it: `agent_nickname`, else the
        /// last component of `agent_path`. Nil falls back to `SubagentActivity.unnamed`.
        let nicknameOrPathName: String?
        let role: String?
        let startedAt: Double
        let startOrdinal: Int?
    }

    /// The running subagents under each root session, oldest first, from the rollouts under `root`
    /// written within `SessionDiscovery.maximumAge` of `now`. Reads at most
    /// `ReminderReader.maximumChildProbes` heads per call, newest first, and the bounded tails of at
    /// most `maximumTails` subagent rollouts; older subagent rollouts are not read. A nested subagent is listed flat under the root its parents lead to. A
    /// rollout that is a symlink, irregular, unreadable, partial, or malformed contributes nothing and
    /// never removes another; a subagent whose turn ended, or whose rollout is gone, is not listed.
    public static func activity(root: URL, now: Double) -> [UUID: [SubagentActivity]] {
        var heads: [UUID: Head] = [:]
        var duplicates: Set<UUID> = []
        var running: [UUID: (head: Head, activity: Activity)] = [:]
        var tails = 0
        for entry in CodexUsageReader.newestRollouts(root: root, limit: ReminderReader.maximumChildProbes)
        where now - entry.modified.timeIntervalSince1970 <= SessionDiscovery.maximumAge {
            guard tails < maximumTails else { break }
            guard let (head, tail) = SessionDiscovery.read(entry.url, header: { bytes in
                bytes.firstIndex(of: UInt8(ascii: "\n")).flatMap { self.head(bytes[bytes.startIndex..<$0]) }
            }) else { continue }
            tails += 1
            guard let lines = events(tail, head: head) else { continue }
            let activity = activity(lines)
            if heads[head.id] != nil { duplicates.insert(head.id) }
            heads[head.id] = head
            if let activity { running[head.id] = (head, activity) }
        }
        // Two rollouts claiming one thread id cannot be told apart: neither is listed or followed.
        for id in duplicates {
            heads.removeValue(forKey: id)
            running.removeValue(forKey: id)
        }
        var byRoot: [UUID: [(head: Head, activity: Activity)]] = [:]
        for child in running.values {
            guard let session = rootSession(of: child.head, heads: heads, duplicates: duplicates) else { continue }
            byRoot[session, default: []].append(child)
        }
        return byRoot.mapValues { children in
            let ordered = children.sorted {
                SubagentActivity.startsBefore(($0.head.startedAt, key($0.head.id)), ($1.head.startedAt, key($1.head.id)))
            }
            let names = SubagentActivity.names(ordered.map { (id: key($0.head.id), base: $0.head.nicknameOrPathName) })
            return ordered.map { child in
                SubagentActivity(id: key(child.head.id), name: names[key(child.head.id)] ?? SubagentActivity.unnamed,
                                 role: child.head.role, asked: child.activity.asked, startedAt: child.head.startedAt,
                                 latestAction: child.activity.latest.flatMap {
                                     RunningRowDetails.now(toolName: $0.name, toolInput: $0.input)
                                 })
            }
        }
    }

    private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    /// The first ancestor that is not itself a subagent rollout read this call. A nested subagent
    /// whose walk stops at a parent that is not a root (a middle agent's rollout missing, stale, or
    /// past the tail budget) falls back to the root its own header names (`session_id`); with no
    /// such root it is left out. Nil past `maximumDepth` or through an ambiguous parent.
    private static func rootSession(of head: Head, heads: [UUID: Head], duplicates: Set<UUID>) -> UUID? {
        var parent = head.parent
        var nested = (head.depth ?? 1) > 1
        for _ in 0..<maximumDepth {
            guard !duplicates.contains(parent) else { return nil }
            guard let next = heads[parent] else {
                guard nested, parent != head.root else { return parent }
                return head.root
            }
            nested = (next.depth ?? 1) > 1
            parent = next.parent
        }
        return nil
    }

    struct Call: Equatable {
        let name: String
        let input: [String: String]
    }

    struct Activity: Equatable {
        let asked: String?
        let latest: Call?
    }

    /// The header of a spawned agent's rollout; nil for any other rollout or an unusable header.
    static func head(_ line: Data) -> Head? {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              event["type"] as? String == "session_meta",
              let meta = event["payload"] as? [String: Any],
              let id = uuid(meta["id"]),
              let spawn = ((meta["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any],
              let parent = CodexRolloutHeader.parent(in: meta),
              let startedAt = ((meta["timestamp"] ?? event["timestamp"]) as? String).flatMap(RolloutTimestamp.parse)
        else { return nil }
        let nickname = text(meta["agent_nickname"]) ?? text(spawn["agent_nickname"])
        let path = text(meta["agent_path"]) ?? text(spawn["agent_path"])
        let name = nickname ?? path.flatMap { text($0.split(separator: "/").last.map(String.init)) }
        return Head(id: id, parent: parent, root: uuid(meta["session_id"]),
                    depth: (spawn["depth"] as? NSNumber)?.intValue, nicknameOrPathName: name,
                    role: text(meta["agent_role"]) ?? text(spawn["agent_role"]), startedAt: startedAt,
                    startOrdinal: (meta["subagent_history_start_ordinal"] as? NSNumber)?.intValue)
    }

    /// The tail's decoded lines from the child's own history on: a line before
    /// `subagent_history_start_ordinal` is the forked parent history and is dropped; a line without an
    /// ordinal is kept. Lines that do not decode (a partial line mid-append, the cut first line) are
    /// skipped. A repeated header that is not the child's, its parent's or the root's makes the whole rollout
    /// unusable (nil), as `ReminderReader.evidence` treats it.
    static func events(_ tail: Data, head: Head) -> [[String: Any]]? {
        var result: [[String: Any]] = []
        for line in tail.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if event["type"] as? String == "session_meta" {
                let repeated = uuid((event["payload"] as? [String: Any])?["id"])
                // The child's own header starts a tail that reaches the file's start.
                guard let repeated, [head.id, head.parent, head.root].contains(repeated) else { return nil }
                continue
            }
            if let start = head.startOrdinal, let ordinal = (event["ordinal"] as? NSNumber)?.intValue, ordinal < start { continue }
            result.append(event)
        }
        return result
    }

    /// The child's task and newest call while its own turn is open (`SessionDiscovery.openTurn`); nil
    /// once that turn ended.
    static func activity(_ events: [[String: Any]]) -> Activity? {
        guard let open = SessionDiscovery.openTurn(in: events)?.turn else { return nil }
        var pending: [String: (order: Int, call: Call)] = [:]
        for (order, event) in events.enumerated() where event["type"] as? String == "response_item" {
            guard let payload = event["payload"] as? [String: Any],
                  SessionDiscovery.turnID(in: payload) == open,
                  let callID = text(payload["call_id"]) else { continue }
            switch payload["type"] as? String {
            case "custom_tool_call_output", "function_call_output":
                pending.removeValue(forKey: callID)
            case "custom_tool_call", "function_call":
                if let call = call(payload) { pending[callID] = (order, call) }
            default:
                break
            }
        }
        return Activity(asked: asked(events), latest: pending.values.max { $0.order < $1.order }?.call)
    }

    /// A tool call as the "now" line names it, the way the session's own Codex calls read: the
    /// desktop engine's `exec` script by the first command it runs, a function call by its name and
    /// its string arguments.
    static func call(_ payload: [String: Any]) -> Call? {
        guard let name = text(payload["name"]) else { return nil }
        if payload["type"] as? String == "custom_tool_call" {
            if name == "exec", let input = payload["input"] as? String,
               let command = CodexToolCallText.commands(inJavaScript: input).first {
                return Call(name: "exec_command", input: ["cmd": command])
            }
            return Call(name: name, input: [:])
        }
        let arguments = (payload["arguments"] as? String).flatMap(CodexToolCallText.jsonObject) ?? [:]
        var input = arguments.compactMapValues { $0 as? String }
        if let command = CodexToolCallText.command(inArguments: arguments) { input["cmd"] = command }
        return Call(name: name, input: input)
    }

    /// The first message the child was given in its own history: a user message, or the task its
    /// parent handed over (`agent_message`, "Message Type: NEW_TASK") when its payload is readable.
    /// Text Codex injects in the user role (environment context, AGENTS.md) is skipped. Kept to
    /// `ClaudeObservationReader.maximumPrompt` characters, like a session's kept prompt.
    static func asked(_ events: [[String: Any]]) -> String? {
        for event in events {
            guard let payload = event["payload"] as? [String: Any] else { continue }
            let kind = payload["type"] as? String
            let found: String?
            switch (event["type"] as? String, kind) {
            case ("event_msg", "user_message"):
                found = payload["message"] as? String
            case ("response_item", "message") where payload["role"] as? String == "user":
                let kinds = (payload["internal_chat_message_metadata_passthrough"] as? [String: Any])?["content_item_kinds"] as? [String]
                guard kinds.map({ $0.contains("user.text") }) ?? true else { continue }
                found = inputText(payload["content"])
            case ("response_item", "agent_message"):
                guard let routed = inputText(payload["content"]), routed.hasPrefix("Message Type: NEW_TASK") else { continue }
                found = routed.range(of: "\nPayload:\n").map { String(routed[$0.upperBound...]) } ?? ""
            default:
                continue
            }
            // The first message decides, even when its text is unreadable (an encrypted payload).
            return QuestionPrompt.display(found, limit: ClaudeObservationReader.maximumPrompt)
        }
        return nil
    }

    private static func inputText(_ content: Any?) -> String? {
        guard let parts = content as? [[String: Any]] else { return nil }
        let texts = parts.filter { $0["type"] as? String == "input_text" }.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }

    private static func text(_ value: Any?) -> String? {
        guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
