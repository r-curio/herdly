/// Focus evidence used to decide whether a completion may be presented.
public enum CompletionFocus: Equatable, Sendable {
    case disabled
    case checking
    case away
    case focused
    case unknown
}

public enum CompletionVisibility {
    /// Whether a completion may pop now. A CLI result waits only while Ghostty is being read
    /// (`checking`) or its tab is focused; an unreadable or not-running Ghostty (`unknown`) shows
    /// nothing visible, so the card pops (#323, ADR 0016). Popping acknowledges nothing, and unknown
    /// focus is never treated as a verified visit. Desktop app identity remains the only desktop gate.
    public static func allows(source: AttentionSource, codexForeground: Bool?, ghosttyFocus: CompletionFocus) -> Bool {
        guard codexForeground != true else { return false }
        switch source {
        case .desktop:
            return true
        case .cli:
            return ghosttyFocus == .disabled || ghosttyFocus == .away || ghosttyFocus == .unknown
        }
    }
}

public enum CompletionSound {
    public static func shouldPlay(firstPresentation: Bool, muted: Bool) -> Bool {
        firstPresentation && !muted
    }
}
