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
