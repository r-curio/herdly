import Foundation
import HerdlyCore

extension Companion {
    /// Hands each row a scan newly queued to the phone rule (#352), with only its project folder.
    /// Called once per scan, after this scan's contexts are recorded so a row's directory is known.
    /// Covers every source the notch shows: Codex desktop and CLI rows arrive through
    /// `syncAgentQueueWithCodex`, Claude rows through its observation scan, both into `agentQueue`.
    /// A row `mayInterrupt` refuses (a paused kind, #456) is still recorded, so it never alerts later.
    func notePhoneAlertArrivals(_ items: [AgentAttentionItem], launchedAt: Double,
                                mayInterrupt: (AgentAttentionItem) -> Bool) {
        let candidates = items.compactMap { item in
            PhoneAlertCandidate(item, project: rowDirectory(for: item) ?? item.approval?.details?.project,
                                launchedAt: launchedAt)?.respecting(mayInterrupt: mayInterrupt(item))
        }
        phoneAlerts.arrived(candidates)
    }
}
