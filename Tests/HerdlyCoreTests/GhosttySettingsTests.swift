import Testing
@testable import HerdlyCore

// The Terminals pane's host rows (product.md, "Agreed terminal host presentation"; #317).

@Test func everyHostExplainsHowOpenWorks() {
    for host in TerminalHost.allCases {
        #expect(!host.howOpenWorks.isEmpty, "\(host) has no How Open Works text")
        #expect(host.howOpenWorks.contains("otherwise Open raises"), "\(host) does not name its Open fallback")
    }
}

@Test func hostsWithAFooterExplainOpenWithExactlyThatFooter() {
    #expect(TerminalHost.iTerm2.howOpenWorks == ITerm2Presentation.footer)
    #expect(TerminalHost.terminalApp.howOpenWorks == TerminalAppPresentation.footer)
    #expect(TerminalHost.wezTerm.howOpenWorks == WezTermPresentation.footer)
    #expect(TerminalHost.tmux.howOpenWorks == TmuxPresentation.footer)
    #expect(TerminalHost.zellij.howOpenWorks == ZellijPresentation.footer)
}

@Test func ghosttyAndHerdrExplainTheirOpenFallback() {
    // ADR 0015 replaced "exact or unavailable": an unreachable tab or pane raises the app instead.
    #expect(TerminalHost.ghostty.howOpenWorks.hasPrefix("Herdly returns to unsplit tabs; otherwise Open raises Ghostty."))
    #expect(!TerminalHost.ghostty.howOpenWorks.contains("unavailable instead of guessing"))
    #expect(TerminalHost.herdr.howOpenWorks.contains("otherwise Open raises that terminal"))
}

private func ghosttyRow(on: Bool = true, installed: Bool = true, supported: Bool = true,
                        access: GhosttyAutomationAccess? = .granted, verified: Bool = true) -> GhosttySettingsRow {
    GhosttyPresentation.settingsRow(on: on, installed: installed, supported: supported, minimum: "1.3.1",
                                    access: access, permissionVerified: verified)
}

@Test func ghosttyRowIsOffWhileItsSwitchIsOff() {
    let row = ghosttyRow(on: false, access: nil, verified: false)
    #expect(row.badge == .off)
    #expect(row.problems.isEmpty)
}

@Test func ghosttyRowIsReadyOnceAccessIsVerified() {
    let row = ghosttyRow()
    #expect(row.badge == .ready)
    #expect(row.problems.isEmpty)
}

@Test func ghosttyRowIsNotInUseWhileAccessIsUnverified() {
    for access: GhosttyAutomationAccess? in [nil, .ghosttyNotRunning, .consentRequired, .unknown(-1)] {
        let row = ghosttyRow(access: access, verified: false)
        #expect(row.badge == .notInUse)
        #expect(row.problems.isEmpty)
    }
}

@Test func deniedAutomationNeedsAttentionAndOffersSettings() {
    let row = ghosttyRow(access: .denied, verified: false)
    #expect(row.badge == .needsAttention)
    #expect(row.problems == [.automationDenied])
    #expect(GhosttySettingsProblem.automationDenied.opensAutomationSettings)
    // A denial turns the switch back off; the line stays so the fix stays visible.
    let off = ghosttyRow(on: false, access: .denied, verified: false)
    #expect(off.badge == .off)
    #expect(off.problems == [.automationDenied])
}

@Test func missingOrOutdatedGhosttyNeedsAttention() {
    let missing = ghosttyRow(installed: false, supported: false, access: nil, verified: false)
    #expect(missing.badge == .needsAttention)
    #expect(missing.problems == [.notFound])
    let outdated = ghosttyRow(supported: false)
    #expect(outdated.badge == .needsAttention)
    #expect(outdated.problems == [.updateNeeded(minimum: "1.3.1")])
    #expect(GhosttySettingsProblem.updateNeeded(minimum: "1.3.1").message == "Update Ghostty to 1.3.1 or later.")
    #expect(!GhosttySettingsProblem.updateNeeded(minimum: "1.3.1").opensAutomationSettings)
}

@Test func everyGhosttyProblemIsListed() {
    let row = ghosttyRow(supported: false, access: .denied, verified: false)
    #expect(row.problems == [.updateNeeded(minimum: "1.3.1"), .automationDenied])
}
