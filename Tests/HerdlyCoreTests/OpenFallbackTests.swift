import Testing
@testable import HerdlyCore

// ADR 0015 (and its 2026-10-11 amendment): when Open cannot reach the exact tab or pane, it raises
// the session's terminal app, found by walking processes, and nothing more. Every process walk, tty
// time and running check is a fixture value here.

// MARK: - Process walk

@Test func walkReachesTheFirstAppBundleAboveTheProcess() {
    // codex → zsh → login → Ghostty's main executable.
    #expect(TerminalAppWalk(ancestorBundleIdentifiers: [nil, nil, nil, "com.mitchellh.ghostty"]) == .reached(.ghostty))
    #expect(TerminalAppWalk(ancestorBundleIdentifiers: [nil, "com.googlecode.iterm2"]) == .reached(.iTerm2))
    #expect(TerminalAppWalk(ancestorBundleIdentifiers: [nil, "com.apple.Terminal"]) == .reached(.terminalApp))
    #expect(TerminalAppWalk(ancestorBundleIdentifiers: [nil, "com.github.wez.wezterm"]) == .reached(.wezTerm))
}

@Test func walkEndingAtAnotherAppIsUnsupportedEvenIfATerminalIsHigher() {
    // An editor's integrated terminal launched from Ghostty: the nearest app decides.
    #expect(TerminalAppWalk(ancestorBundleIdentifiers: [nil, "com.microsoft.VSCode", "com.mitchellh.ghostty"])
        == .unsupportedApp)
}

@Test func walkWithoutAnyAppFails() {
    // An exited process, or a multiplexer server whose parent is launchd.
    #expect(TerminalAppWalk(ancestorBundleIdentifiers: []) == .failed)
    #expect(TerminalAppWalk(ancestorBundleIdentifiers: [nil, nil]) == .failed)
}

// MARK: - Which app: Codex candidates (amendment)

private let allOn = TerminalHostSwitches(enabled: Set(TerminalHost.allCases))

private func candidate(_ walk: TerminalAppWalk, _ written: Double?) -> CodexOpenCandidate {
    CodexOpenCandidate(walk: walk, ttyWrittenAt: written)
}

@Test func codexCandidatesInOneAppRaiseItWithoutReadingTTYTimes() {
    let candidates = [candidate(.reached(.ghostty), nil), candidate(.reached(.ghostty), nil)]
    #expect(OpenFallback.codexApp(candidates: candidates, switches: allOn) == .success(.ghostty))
}

@Test func codexCandidatesInDifferentAppsRaiseTheAppWhoseTTYWasWrittenLast() {
    let candidates = [candidate(.reached(.ghostty), 100), candidate(.reached(.iTerm2), 101.5)]
    #expect(OpenFallback.codexApp(candidates: candidates, switches: allOn) == .success(.iTerm2))
    let reversed = [candidate(.reached(.ghostty), 103), candidate(.reached(.iTerm2), 101.5)]
    #expect(OpenFallback.codexApp(candidates: reversed, switches: allOn) == .success(.ghostty))
}

@Test func codexCandidatesWrittenWithinOneSecondCannotBeIdentified() {
    for later in [100.0, 100.4, 101.0] {
        let candidates = [candidate(.reached(.ghostty), 100), candidate(.reached(.wezTerm), later)]
        #expect(OpenFallback.codexApp(candidates: candidates, switches: allOn) == .failure(.appNotIdentified))
    }
    // Just past the one-second tie, the later tab wins.
    let candidates = [candidate(.reached(.ghostty), 100), candidate(.reached(.wezTerm), 101.001)]
    #expect(OpenFallback.codexApp(candidates: candidates, switches: allOn) == .success(.wezTerm))
}

@Test func codexCandidatesInDifferentAppsWithAnUnreadableTTYTimeCannotBeIdentified() {
    let candidates = [candidate(.reached(.ghostty), 100), candidate(.reached(.iTerm2), nil),
                      candidate(.reached(.iTerm2), 50)]
    #expect(OpenFallback.codexApp(candidates: candidates, switches: allOn) == .failure(.appNotIdentified))
}

@Test func codexWithoutCandidatesOrWithAFailedWalkCannotBeIdentified() {
    #expect(OpenFallback.codexApp(candidates: [], switches: allOn) == .failure(.appNotIdentified))
    for bad in [TerminalAppWalk.failed, .unsupportedApp] {
        let candidates = [candidate(.reached(.ghostty), 100), candidate(bad, 200)]
        #expect(OpenFallback.codexApp(candidates: candidates, switches: allOn) == .failure(.appNotIdentified))
    }
}

@Test func codexSessionInASwitchedOffAppCannotBeIdentified() {
    let ghosttyOnly = TerminalHostSwitches(enabled: [.ghostty])
    #expect(OpenFallback.codexApp(candidates: [candidate(.reached(.iTerm2), 100)], switches: ghosttyOnly)
        == .failure(.appNotIdentified))
    #expect(OpenFallback.codexApp(candidates: [candidate(.reached(.ghostty), 100)], switches: ghosttyOnly)
        == .success(.ghostty))
}

// MARK: - Which app: a session's own process or a multiplexer's clients

@Test func claudeInASwitchedOffAppStillFallsBackThroughItsRegistryProcess() {
    let nothingOn = TerminalHostSwitches()
    #expect(OpenFallback.processApp(walks: [.reached(.iTerm2)], agent: .claude, switches: nothingOn) == .success(.iTerm2))
}

@Test func codexMultiplexerClientInASwitchedOffAppCannotBeIdentified() {
    let ghosttyOnly = TerminalHostSwitches(enabled: [.ghostty, .herdr])
    #expect(OpenFallback.processApp(walks: [.reached(.iTerm2)], agent: .codex, switches: ghosttyOnly)
        == .failure(.appNotIdentified))
    #expect(OpenFallback.processApp(walks: [.reached(.ghostty)], agent: .codex, switches: ghosttyOnly)
        == .success(.ghostty))
}

@Test func processWalksMustAllReachOneSupportedApp() {
    // Two multiplexer clients in the same app raise it; in different apps, nothing can be identified.
    #expect(OpenFallback.processApp(walks: [.reached(.ghostty), .reached(.ghostty)], agent: .claude, switches: allOn)
        == .success(.ghostty))
    #expect(OpenFallback.processApp(walks: [.reached(.ghostty), .reached(.wezTerm)], agent: .claude, switches: allOn)
        == .failure(.appNotIdentified))
    // No process (no registry PID, no attached client), a failed walk, or an unsupported app.
    for walks in [[], [TerminalAppWalk.failed], [.unsupportedApp], [.reached(.ghostty), .failed]] {
        #expect(OpenFallback.processApp(walks: walks, agent: .claude, switches: allOn) == .failure(.appNotIdentified))
    }
}

// MARK: - Resolution

@Test func fallbackRaisesTheIdentifiedRunningApp() {
    for reason in [OpenFallbackReason.noUniqueTarget, .unsupportedLayout, .partialReach, .notVerified] {
        #expect(OpenFallback.resolve(reason, app: .success(.ghostty), isRunning: { $0 == .ghostty })
            == .fellBack(.ghostty, reason))
    }
}

@Test func fallbackNeverLaunchesAnAppThatIsNotRunning() {
    #expect(OpenFallback.resolve(.unsupportedLayout, app: .success(.iTerm2), isRunning: { $0 == .ghostty })
        == .unavailable(.appNotRunning(.iTerm2)))
}

@Test func fallbackWithoutAnIdentifiedAppIsUnavailable() {
    #expect(OpenFallback.resolve(.noUniqueTarget, app: .failure(.appNotIdentified), isRunning: { _ in true })
        == .unavailable(.appNotIdentified))
}

@Test func onlyAVerifiedOpenAcknowledgesAndAFallbackIsSilent() {
    #expect(TerminalOpenResult.opened.acknowledges)
    #expect(!TerminalOpenResult.fellBack(.ghostty, .unsupportedLayout).acknowledges)
    #expect(!TerminalOpenResult.unavailable(.sessionEnded).acknowledges)
    // No message for a fallback (silent) or a verified Open; each unavailable case keeps its agreed line.
    #expect(TerminalOpenResult.fellBack(.ghostty, .noUniqueTarget).unavailableLine == nil)
    #expect(TerminalOpenResult.opened.unavailableLine == nil)
    #expect(TerminalOpenResult.unavailable(.hostUnreadable(.iTerm2)).unavailableLine
        == "Herdly can't read iTerm2. Check Settings › Terminals.")
    #expect(TerminalOpenResult.unavailable(.appNotRunning(.iTerm2)).unavailableLine == "iTerm2 isn't running.")
    #expect(TerminalOpenResult.unavailable(.appNotIdentified).unavailableLine
        == "Herdly can't tell which terminal this session is in.")
    #expect(TerminalOpenResult.unavailable(.sessionEnded).unavailableLine == "This session has ended.")
}

@Test func aMissResolvesWithoutEverReportingAVerifiedOpen() {
    // A miss has no exact case, so it can never become `.opened` or acknowledge.
    #expect(OpenFallback.resolve(OpenMiss.unavailable(.sessionEnded), app: { _ in .success(.ghostty) },
                                 isRunning: { _ in true }) == .unavailable(.sessionEnded))
    #expect(OpenFallback.resolve(OpenMiss.fallBack(.unsupportedLayout, candidates: 1), app: { count in
        count == 1 ? .success(.ghostty) : .failure(.appNotIdentified)
    }, isRunning: { _ in true }) == .fellBack(.ghostty, .unsupportedLayout))
    #expect(OpenFallback.resolve(OpenMiss.fallBack(.noUniqueTarget, candidates: 0), app: { _ in .failure(.appNotIdentified) },
                                 isRunning: { _ in true }) == .unavailable(.appNotIdentified))
}

@Test func activationFailureIsReportedTruthfully() {
    let fallback = TerminalOpenResult.fellBack(.ghostty, .unsupportedLayout)
    #expect(OpenFallback.afterActivation(fallback, activated: true, stillRunning: true) == fallback)
    // The app quit between the check and the activation.
    #expect(OpenFallback.afterActivation(fallback, activated: false, stillRunning: false)
        == .unavailable(.appNotRunning(.ghostty)))
    // Still running, but macOS did not activate it: never claimed as "isn't running".
    let refused = OpenFallback.afterActivation(fallback, activated: false, stillRunning: true)
    #expect(refused == .unavailable(.activationFailed(.ghostty)))
    #expect(refused.unavailableLine == "Herdly couldn't bring Ghostty forward.")
    #expect(!refused.acknowledges)
    // Nothing to activate for a verified Open or an unavailable one.
    #expect(OpenFallback.afterActivation(.opened, activated: false, stillRunning: false) == .opened)
}
