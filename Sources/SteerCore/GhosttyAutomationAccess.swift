import Foundation

/// macOS's Automation (Apple Events) consent for Steer to control Ghostty, as reported by
/// `AEDeterminePermissionToAutomateTarget`. A check sends no Apple Event and reads no tabs.
public enum GhosttyAutomationAccess: Equatable, Sendable {
    case granted
    /// The user declined, or turned Steer off under Privacy & Security › Automation.
    case denied
    /// Consent can be determined only while Ghostty is running.
    case ghosttyNotRunning
    /// No decision yet and the check was not allowed to ask.
    case consentRequired
    case unknown(Int32)

    public init(status: Int32) {
        switch status {
        case 0: self = .granted
        case -1743: self = .denied            // errAEEventNotPermitted
        case -600: self = .ghosttyNotRunning   // procNotFound
        case -1744: self = .consentRequired    // errAEEventWouldRequireUserConsent
        default: self = .unknown(status)
        }
    }
}

/// The remembered Ghostty controls preference and its first-launch offer.
public enum GhosttyControlsPolicy {
    public enum Outcome: Equatable, Sendable {
        /// Access is granted; controls may read Ghostty's tabs.
        case verified
        /// The user denied access: switch controls off and remember that.
        case disable
        /// Keep controls on and check again when Ghostty launches.
        case awaitGhostty
        /// Keep controls on without marking access verified.
        case unverified
    }

    public static func outcome(for access: GhosttyAutomationAccess) -> Outcome {
        switch access {
        case .granted: .verified
        case .denied: .disable
        case .ghosttyNotRunning: .awaitGhostty
        case .consentRequired, .unknown: .unverified
        }
    }

    /// What a failed tab scan does, given the silent consent check that follows it.
    public enum ScanFailure: Equatable, Sendable {
        /// A denial or Ghostty not running: apply `outcome(for:)` as for any consent check.
        case applyAccess
        /// Access is not refused, so the failure is a passing one (Ghostty busy, starting or past
        /// the scan deadline): keep controls on, treat tabs as unknown, and scan again.
        case retry
    }

    public static func afterFailedScan(_ access: GhosttyAutomationAccess) -> ScanFailure {
        switch access {
        case .denied, .ghosttyNotRunning: .applyAccess
        case .granted, .consentRequired, .unknown: .retry
        }
    }

    /// Offer Ghostty controls once, only before the user has ever chosen. Callers skip preview and
    /// probe launches before asking.
    public static func shouldOfferFirstRun(offeredBefore: Bool, storedPreference: Bool?) -> Bool {
        !offeredBefore && storedPreference == nil
    }
}
