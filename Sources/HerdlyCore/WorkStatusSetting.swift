/// The "Pull request status on finished rows" switch: the user's choice once made; until then on
/// only while `gh` is installed and signed in.
public enum WorkStatusSetting {
    public static let defaultsKey = "workStatusEnabled"
    /// The last GitHub CLI check (`GitHubCLIStatus.remembered`).
    public static let rememberedCLIKey = "gitHubCLILastCheck"

    public static func isOn(stored: Bool?, cli: GitHubCLIStatus) -> Bool {
        stored ?? cli.isSignedIn
    }

    /// Whether the card may run `gh`: not once the user turned the switch off. Undecided may, since
    /// its default depends on the check.
    public static func mayCheckCLI(stored: Bool?) -> Bool { stored != false }

    /// The switch row shows while signed in, and in every state once the user has made a choice, so a
    /// switch turned off can always be turned back on. Otherwise signed out, not installed and unknown
    /// show no switch.
    public static func showsSwitch(stored: Bool?, cli: GitHubCLIStatus) -> Bool {
        stored != nil || cli.isSignedIn
    }
}
