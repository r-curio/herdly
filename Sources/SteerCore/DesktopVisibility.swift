public enum DesktopVisibility {
    /// Confirmed Codex foreground hides the shared panel; away and unknown keep activity visible.
    public static func isVisible(hasActivity: Bool, codexForeground: Bool?) -> Bool {
        hasActivity && codexForeground != true
    }
}
