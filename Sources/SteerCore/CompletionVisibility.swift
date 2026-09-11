/// Focus evidence used to decide whether a completion may be presented.
public enum CompletionFocus: Equatable, Sendable {
    case disabled
    case checking
    case away
    case focused
    case unknown
}

public enum CompletionVisibility {
    /// Unknown Ghostty focus is never treated as a verified visit. Desktop app
    /// identity remains the only desktop visibility gate.
    public static func allows(source: AttentionSource, codexForeground: Bool?, ghosttyFocus: CompletionFocus) -> Bool {
        guard codexForeground != true else { return false }
        switch source {
        case .desktop:
            return true
        case .cli:
            return ghosttyFocus == .disabled || ghosttyFocus == .away
        }
    }
}
