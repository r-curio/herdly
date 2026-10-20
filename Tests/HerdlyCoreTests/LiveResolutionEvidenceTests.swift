import Foundation
import Testing
@testable import HerdlyCore

/// Runs the real reader against a recorded lab events directory and the user's rollouts.
/// Skipped unless HERDLY_LIVE_EVENTS is set; it never writes anything except the optional report.
///
///   HERDLY_LIVE_EVENTS=scripts/cli-approval-lab/events-native-deny \
///   HERDLY_LIVE_ROLLOUTS=$HOME/.codex/sessions HERDLY_LIVE_REPORT=/tmp/report.json \
///   swift test --filter liveResolutionEvidence
@Test func liveResolutionEvidence() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let eventsPath = environment["HERDLY_LIVE_EVENTS"] else { return }
    let events = URL(fileURLWithPath: eventsPath)
    let rollouts = URL(fileURLWithPath: environment["HERDLY_LIVE_ROLLOUTS"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions").path)
    let scan = ReminderReader.scan(events: events, rollouts: rollouts)
    var queue = AttentionQueue()
    queue.apply(scan: scan, desktopEvents: [], now: Date().timeIntervalSince1970)
    let report: [String: Any] = [
        "events": eventsPath,
        "recorded_requests": scan.attentionRequests.map { ["request_id": $0.id.uuidString, "session": $0.session.uuidString,
                                                          "turn": $0.turn.uuidString, "source": $0.source.rawValue,
                                                          "command": $0.details?.command ?? "", "state": "\($0.state)"] },
        "resolutions": scan.resolvedRequests.map { ["request_id": $0.requestID.uuidString, "kind": $0.kind.rawValue,
                                                    "call_id": $0.callID, "observed_at": $0.observedAt] },
        "completed_turns": scan.completed.map { "\($0.session)/\($0.turn)" },
        "canceled_turns": scan.canceled.map { "\($0.session)/\($0.turn)" },
        "remaining_queue_requests": queue.items.compactMap(\.request).map { $0.id.uuidString },
        "pending_questions": scan.questions.map { ["session": $0.session.uuidString, "turn": $0.turn.uuidString, "call_id": $0.callID,
                                                  "source": $0.source.rawValue, "asked_at": $0.arrivedAt, "questions": $0.prompts.count] },
        "answered_questions": scan.answeredQuestions.map { "\($0.session)/\($0.callID)" }
    ]
    let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    if let path = environment["HERDLY_LIVE_REPORT"] { try bytes.write(to: URL(fileURLWithPath: path)) }
    print(String(decoding: bytes, as: UTF8.self))
}
