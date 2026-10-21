import Foundation

/// One independent fix listed under Ghostty's row in Settings › Terminals.
public enum GhosttySettingsProblem: Equatable, Hashable, Sendable {
    /// Ghostty is not installed in a location Herdly checks.
    case notFound
    /// The installed Ghostty is older than the version Herdly needs.
    case updateNeeded(minimum: String)
    /// macOS Automation access for Ghostty was denied.
    case automationDenied

    public var message: String {
        switch self {
        case .notFound: "Herdly can't find Ghostty on this Mac."
        case .updateNeeded(let minimum): "Update Ghostty to \(minimum) or later."
        case .automationDenied: "Herdly isn't allowed to control Ghostty. Turn on Herdly › Ghostty in System Settings › Privacy & Security › Automation, then turn Ghostty on here."
        }
    }

    /// Whether the line offers Open Settings…, which opens Privacy & Security › Automation.
    public var opensAutomationSettings: Bool { self == .automationDenied }
}

/// Ghostty's row: the status badge and every problem that applies.
public struct GhosttySettingsRow: Equatable, Sendable {
    public let badge: HerdrReadinessBadge
    public let problems: [GhosttySettingsProblem]

    public init(badge: HerdrReadinessBadge, problems: [GhosttySettingsProblem]) {
        self.badge = badge
        self.problems = problems
    }
}

public enum GhosttyPresentation {
    /// The row's targeting rule and what Open does otherwise; a fallback is silent on notch cards (ADR
    /// 0015), so How Open Works… is where it is explained. Ghostty's typed replies wait for live proof
    /// (ADR 0017), so only question options are named.
    public static let howOpenWorks =
        "Herdly returns to unsplit tabs; otherwise Open raises Ghostty. Codex question options are sent to the exact tab."

    /// The row from the switch, the installed Ghostty, the latest Automation check and whether a scan
    /// has verified access. A denial turns the switch back off, so its line is listed whatever the switch
    /// says; a missing or outdated Ghostty is listed only while the switch is on. Access that is neither verified
    /// nor denied (not checked yet, Ghostty not running, consent not yet given) reads Not in use: nothing
    /// has been seen there and macOS asks when Ghostty next opens.
    public static func settingsRow(on: Bool, installed: Bool, supported: Bool, minimum: String,
                                   access: GhosttyAutomationAccess?, permissionVerified: Bool) -> GhosttySettingsRow {
        var problems: [GhosttySettingsProblem] = []
        if on, !installed {
            problems.append(.notFound)
        } else if on, !supported {
            problems.append(.updateNeeded(minimum: minimum))
        }
        if access == .denied, !permissionVerified { problems.append(.automationDenied) }
        let badge: HerdrReadinessBadge = !on ? .off : !problems.isEmpty ? .needsAttention
            : permissionVerified ? .ready : .notInUse
        return GhosttySettingsRow(badge: badge, problems: problems)
    }
}
