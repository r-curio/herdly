import Foundation

/// The Claude permission requests Steer may decide directly, and how each one is shown.
///
/// Bash was the first proven family. The file family (`Edit`, `Write`, `NotebookEdit`, and `Read` outside the
/// working folders) was proven in [claude-file-approvals](../../docs/evidence/claude-file-approvals.md) on Claude
/// Code 2.1.296. Each accepted request must have exactly a key set observed there: a key the tool schema allows
/// but the proof never saw (or a missing one), a wrong type, or a relative path returns nil, so the helper waits
/// for no decision and Claude's own dialog stays in charge. The web family (`WebFetch`, `WebSearch`) follows the
/// same rule from [claude-web-approvals](../../docs/evidence/claude-web-approvals.md). `ExitPlanMode` and MCP tools
/// are excluded: Claude ignores a hook allow for plan approval, and an MCP call's consequence cannot be shown.
public enum ClaudeDirectApproval {
    /// The tools whose `PermissionRequest` the helper waits on for a Steer decision.
    public static let tools: Set<String> = ["Bash", "Edit", "Write", "NotebookEdit", "Read", "WebFetch", "WebSearch"]
    /// The file family's hook matcher. Bash keeps its own installed matcher so existing installs stay exact.
    public static let fileMatcher = "Edit|Write|NotebookEdit|Read"
    /// The web family's hook matcher, in its own entry so file entries already installed stay exact.
    public static let webMatcher = "WebFetch|WebSearch"
    /// The longest URL or search query accepted, in UTF-8 bytes, within the helper's 4,096-byte kept-input bound.
    public static let maximumURL = 2_048
    public static let maximumQuery = 500
    /// Characters of edited, written, or notebook text shown before the preview is cut.
    public static let maximumPreview = 2_000
    /// The longest absolute path accepted.
    public static let maximumPath = 4_096

    /// True when Steer may decide this request. Bash is accepted by name alone, as before this family existed.
    public static func accepts(toolName: String, toolInput: [String: Any]) -> Bool {
        toolName == "Bash" || details(toolName: toolName, toolInput: toolInput) != nil
    }

    /// What the row and spotlight show for one decidable file request: Claude's own name for the action, the
    /// full absolute path, and a bounded, labeled preview of what the action does.
    public static func details(toolName: String, toolInput input: [String: Any]) -> ApprovalDetails? {
        switch toolName {
        case "Edit":
            guard keys(input, required: ["file_path", "old_string", "new_string", "replace_all"]),
                  let path = path(input["file_path"]), let old = input["old_string"] as? String,
                  let new = input["new_string"] as? String, let replaceAll = input["replace_all"].flatMap(bool) else { return nil }
            let scope = replaceAll ? "Replace every occurrence of" : "Replace"
            return ApprovalDetails(action: "Edit file", command: path,
                                   longText: "\(scope):\n\(preview(old))\n\nWith:\n\(preview(new))",
                                   commandLabel: "path")
        case "Write":
            guard keys(input, required: ["file_path", "content"]),
                  let path = path(input["file_path"]), let content = input["content"] as? String else { return nil }
            // The hook input does not say whether the file exists, so the action claims neither create nor overwrite.
            return ApprovalDetails(action: "Write file", command: path,
                                   longText: "Content (\(content.count) characters):\n\(preview(content))",
                                   commandLabel: "path")
        case "NotebookEdit":
            // Each edit mode accepts exactly the keys it was observed with.
            guard let mode = input["edit_mode"] as? String, let path = path(input["notebook_path"]),
                  let cell = cellID(input["cell_id"]), let source = input["new_source"] as? String else { return nil }
            let summary: String
            switch mode {
            case "replace":
                guard keys(input, required: ["notebook_path", "cell_id", "new_source", "edit_mode"]) else { return nil }
                summary = "Replace the source of cell \(cell):\n\(preview(source))"
            case "insert":
                guard keys(input, required: ["notebook_path", "cell_id", "new_source", "cell_type", "edit_mode"]),
                      input["cell_type"] as? String == "code" else { return nil }
                summary = "Insert a new code cell after cell \(cell):\n\(preview(source))"
            case "delete":
                guard keys(input, required: ["notebook_path", "cell_id", "new_source", "edit_mode"]), source.isEmpty else { return nil }
                summary = "Delete cell \(cell)"
            default:
                return nil
            }
            return ApprovalDetails(action: "Edit notebook", command: path, longText: summary, commandLabel: "path")
        case "Read":
            guard let path = path(input["file_path"]) else { return nil }
            if keys(input, required: ["file_path"]) {
                return ApprovalDetails(action: "Read file", command: path, commandLabel: "path")
            }
            guard keys(input, required: ["file_path", "offset", "limit"]),
                  let offset = integer(input["offset"]), offset >= 0,
                  let limit = integer(input["limit"]), limit >= 0 else { return nil }
            return ApprovalDetails(action: "Read file", command: path,
                                   longText: "Lines: offset \(offset), limit \(limit)", commandLabel: "path")
        case "WebFetch":
            // Every new URL, including a redirect target, arrives as its own request (#73), so the URL shown is
            // exactly the one fetched.
            guard keys(input, required: ["url", "prompt"]), let url = url(input["url"]), let host = host(of: url),
                  let prompt = input["prompt"] as? String else { return nil }
            return ApprovalDetails(action: "Fetch web page", command: url,
                                   longText: "Host: \(host.lowercased())\n\nClaude asks of the page:\n\(preview(prompt))",
                                   commandLabel: "url")
        case "WebSearch":
            guard keys(input, required: ["query", "mode"]), input["mode"] as? String == "standard",
                  let query = query(input["query"]) else { return nil }
            return ApprovalDetails(action: "Search the web", command: query, commandLabel: "query")
        default:
            return nil
        }
    }

    /// True when `command` is a value this family could have produced for `label`, so a reader can re-check
    /// the helper's details without trusting them.
    public static func validCommand(_ command: String?, label: String?) -> Bool {
        switch label {
        case "path": return path(command) != nil
        case "url": return url(command) != nil
        case "query": return query(command) != nil
        default: return false
        }
    }

    /// The path a request targets, for matching the request to its `PreToolUse` call.
    public static func target(toolName: String, toolInput: [String: Any]) -> String? {
        switch toolName {
        case "NotebookEdit": return toolInput["notebook_path"] as? String
        case "Edit", "Write", "Read": return toolInput["file_path"] as? String
        case "WebFetch": return toolInput["url"] as? String
        case "WebSearch": return toolInput["query"] as? String
        default: return nil
        }
    }

    private static func keys(_ input: [String: Any], required: Set<String>) -> Bool {
        Set(input.keys) == required
    }

    /// An absolute path shown exactly as it will be used: no control, format, or bidirectional characters
    /// that could make the displayed path read differently, and no surrounding whitespace a display might trim.
    public static func path(_ value: Any?) -> String? {
        guard let path = value as? String, path.hasPrefix("/"), path.utf8.count <= maximumPath,
              path == path.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.unicodeScalars.contains(where: unsafeForDisplay) else { return nil }
        return path
    }

    /// An absolute https URL in the plain form observed, `https://<host>[/...]`, shown exactly as fetched.
    ///
    /// Claude parses URLs the WHATWG way and Foundation does not, and the two disagree on backslashes, userinfo,
    /// and encoded hosts (`https://evil.com\@example.com/` is example.com to one and evil.com to the other). So
    /// the host is read here without either parser: the authority must be a plain ASCII hostname, with no
    /// userinfo, port, or percent-encoding, and the URL may not contain a backslash. Anything else stays native.
    public static func url(_ value: Any?) -> String? {
        guard let url = value as? String, url.utf8.count <= maximumURL, !url.contains("\\"),
              !url.unicodeScalars.contains(where: { CharacterSet.whitespaces.contains($0) || unsafeForDisplay($0) || !$0.isASCII }),
              host(of: url) != nil, URLComponents(string: url) != nil else { return nil }
        return url
    }

    /// The hostname of a plain `https://` URL: the text up to the first `/`, `?`, or `#`, made only of ASCII
    /// letters, digits, hyphens, and dots. Punycode (`xn--`) is kept as written, never shown decoded.
    static func host(of url: String) -> String? {
        let prefix = "https://"
        guard url.lowercased().hasPrefix(prefix) else { return nil }
        let rest = url.dropFirst(prefix.count)
        let host = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        guard !host.isEmpty, host.count <= 253, host.allSatisfy(allowed.contains), !host.hasPrefix("."),
              !host.hasPrefix("-"), !host.contains("..") else { return nil }
        // A WHATWG parser reads a host whose last label is a number (decimal, or 0x hex) as an IPv4 address,
        // so "0x7f.1" would be fetched as 127.0.0.1. Such hosts are not shown as names.
        let last = host.split(separator: ".").last.map(String.init) ?? ""
        let hex = last.lowercased().hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit)
        guard !last.isEmpty, !last.allSatisfy(\.isNumber), !hex else { return nil }
        return String(host)
    }

    /// A non-empty single-line query without control, format, or bidirectional characters.
    public static func query(_ value: Any?) -> String? {
        guard let query = value as? String, !query.isEmpty, query.utf8.count <= maximumQuery,
              query == query.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.unicodeScalars.contains(where: unsafeForDisplay) else { return nil }
        return query
    }

    private static func cellID(_ value: Any?) -> String? {
        guard let id = value as? String, !id.isEmpty, id.count <= 256,
              !id.unicodeScalars.contains(where: unsafeForDisplay) else { return nil }
        return id
    }

    /// Control, format (including bidirectional overrides), and line or paragraph separator characters, any of
    /// which could make a shown target read differently from the real one.
    private static func unsafeForDisplay(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
            || scalar.properties.generalCategory == .format
            || scalar.properties.generalCategory == .lineSeparator || scalar.properties.generalCategory == .paragraphSeparator
    }

    /// The text as shown: characters a terminal or the notch could act on are replaced, and past
    /// `maximumPreview` characters it is cut with a label saying so.
    private static func preview(_ text: String) -> String {
        let safe = String(text.map { ["\u{0}", "\u{1b}", "\u{7}"].contains($0) ? "\u{FFFD}" : $0 })
        guard safe.count > maximumPreview else { return safe.isEmpty ? "(empty)" : safe }
        return String(safe.prefix(maximumPreview)) + "\n… shortened; \(text.count) characters in all. The full text is in Claude."
    }

    /// JSON booleans only; Foundation also bridges 0 and 1 to Bool, which this rejects.
    private static func bool(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// JSON integers only, never booleans or fractions.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number as CFNumber), let int = Int(exactly: number.int64Value) else { return nil }
        return int
    }
}
