public enum DesktopVisibility {
    /// The notch stays available in every app, including when there is no activity.
    /// Focus still governs acknowledgment and notification delivery separately.
    public static func isVisible(hasActivity: Bool, codexForeground: Bool?) -> Bool {
        true
    }
}
