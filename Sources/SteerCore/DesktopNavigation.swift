import Foundation

public enum NavigationResult: String {
    case invalidTask = "Enter a valid task ID."
    case unavailable = "Open your preferred Codex app first. Its installation could not be identified."
    case ambiguous = "Multiple Codex instances are running. Keep only the intended instance open, then retry."
    case requestedUnverified = "Link sent to Codex. Task selection could not be verified; the notification stays queued."
    case failed = "The link could not be opened. The notification stays queued."
}

/// No result represents a verified task visit or acknowledges a completion.
public enum DesktopNavigation {
    @MainActor
    public static func open(
        taskID: String,
        runningAppURLs: [URL?],
        using opener: (URL, URL) async throws -> Void
    ) async -> NavigationResult {
        guard let id = UUID(uuidString: taskID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .invalidTask
        }
        guard runningAppURLs.count <= 1 else { return .ambiguous }
        guard let appURL = runningAppURLs.first ?? nil, appURL.isFileURL else { return .unavailable }
        let taskURL = URL(string: "codex://threads/\(id.uuidString.lowercased())")!
        do {
            try await opener(taskURL, appURL)
            // Even a nonexistent task can produce a successful native URL-open callback.
            return .requestedUnverified
        } catch {
            return .failed
        }
    }
}
