import Foundation

/// The GitHub card's state (Paper "GitHub status in Agents", #417): the GitHub CLI's presence and
/// sign-in.
public enum GitHubCLIStatus: Equatable, Sendable {
    case checking
    case notInstalled
    case signedOut(version: String?)
    case signedIn(version: String?)
    /// Installed, but its sign-in could not be read (offline, timed out, unreadable), or the switch is
    /// off and no earlier check is remembered. Not one of the Paper frames: it is the explicit
    /// uncertainty state.
    case unknown(version: String?)

    public var subtitle: String {
        switch self {
        case .checking: "GitHub CLI"
        case .notInstalled: "GitHub CLI not installed"
        case .signedOut(let version): "\(Self.name(version)) · signed out"
        case .signedIn(let version): "\(Self.name(version)) · signed in to github.com"
        case .unknown(let version): "\(Self.name(version)) · sign-in unknown"
        }
    }

    public var header: AgentHeaderStatus {
        switch self {
        case .checking: .checking
        case .signedIn: .connected
        case .signedOut: .attention("Sign in required")
        case .notInstalled: .unavailable("Not installed")
        case .unknown: .unavailable("Status unknown")
        }
    }

    private static func name(_ version: String?) -> String {
        version.map { "GitHub CLI \($0)" } ?? "GitHub CLI"
    }

    /// "gh version 2.62.0 (2024-11-14)" → "2.62.0".
    public static func version(_ output: String) -> String? {
        guard let line = output.split(separator: "\n").first, line.hasPrefix("gh version ") else { return nil }
        let value = line.dropFirst("gh version ".count).split(separator: " ").first.map(String.init) ?? ""
        guard !value.isEmpty, value.count <= 32,
              value.allSatisfy({ $0.isNumber || $0 == "." || $0.isLetter || $0 == "-" }) else { return nil }
        return value
    }

    /// `gh auth status --hostname github.com --json hosts`: signed in when the active github.com
    /// account's state is "success", signed out when github.com has no account, nil otherwise.
    public static func signedIn(_ data: Data) -> Bool? {
        struct Status: Decodable { let hosts: [String: [Account]] }
        struct Account: Decodable { let state: String; let active: Bool }
        guard data.count <= 64 * 1024, let status = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
        let accounts = status.hosts["github.com"] ?? []
        if accounts.isEmpty { return false }
        guard let active = accounts.first(where: \.active) else { return nil }
        return active.state == "success" ? true : nil
    }

    // MARK: Remembered check

    /// The last check, kept so the card can show it while the switch is off and no `gh` may run.
    /// Only the version and whether github.com was signed in; never an account or token.
    public var remembered: String? {
        switch self {
        case .checking, .notInstalled, .unknown: nil
        case .signedIn(let version): "signedIn " + (version ?? "")
        case .signedOut(let version): "signedOut " + (version ?? "")
        }
    }

    public static func remembered(_ text: String?) -> GitHubCLIStatus? {
        guard let text, text.count <= 64 else { return nil }
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[1].contains(" ") else { return nil }
        let version: String? = parts[1].isEmpty ? nil : version("gh version \(parts[1])")
        guard parts[1].isEmpty || version != nil else { return nil }
        switch parts[0] {
        case "signedIn": return .signedIn(version: version)
        case "signedOut": return .signedOut(version: version)
        default: return nil
        }
    }

    /// The card while the switch is off (#417): no `gh` runs, so not installed is found on disk alone;
    /// otherwise the last check, or unknown when none is remembered.
    public static func withoutRunning(installed: Bool, remembered: GitHubCLIStatus?) -> GitHubCLIStatus {
        guard installed else { return .notInstalled }
        return remembered ?? .unknown(version: nil)
    }
}

/// The "Pull request status on finished rows" switch: the user's choice once made; until then on
/// only while `gh` is installed and signed in.
public enum WorkStatusSetting {
    public static let defaultsKey = "workStatusEnabled"
    /// The last GitHub CLI check (`GitHubCLIStatus.remembered`).
    public static let rememberedCLIKey = "gitHubCLILastCheck"

    public static func isOn(stored: Bool?, cli: GitHubCLIStatus) -> Bool {
        if let stored { return stored }
        if case .signedIn = cli { return true }
        return false
    }

    /// Whether the card may run `gh`: not once the user turned the switch off. Undecided may, since
    /// its default depends on the check.
    public static func mayCheckCLI(stored: Bool?) -> Bool { stored != false }

    /// The switch row shows while signed in, and whenever the user has it on, so it can always be
    /// turned off. Signed out, not installed and unknown otherwise show no switch.
    public static func showsSwitch(stored: Bool?, cli: GitHubCLIStatus) -> Bool {
        if stored == true { return true }
        if case .signedIn = cli { return true }
        return false
    }
}

/// Where Herdly looks for `git` and `gh`. The app does not inherit the shell's PATH. `/usr/bin/git` is
/// never used: without the developer tools it is a stub that offers to install them.
public enum WorkStatusTools {
    public static func git(isExecutable: (String) -> Bool) -> String? {
        ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
         "/Applications/Xcode.app/Contents/Developer/usr/bin/git"].first(where: isExecutable)
    }

    public static func gh(home: String, isExecutable: (String) -> Bool) -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(home)/.local/bin/gh", "/usr/bin/gh"].first(where: isExecutable)
    }
}
