import Testing
@testable import SteerCore

@Test func automationStatusesMapToAccess() {
    #expect(GhosttyAutomationAccess(status: 0) == .granted)
    #expect(GhosttyAutomationAccess(status: -1743) == .denied)
    #expect(GhosttyAutomationAccess(status: -600) == .ghosttyNotRunning)
    #expect(GhosttyAutomationAccess(status: -1744) == .consentRequired)
    #expect(GhosttyAutomationAccess(status: -50) == .unknown(-50))
}

@Test func onlyDenialSwitchesGhosttyControlsOff() {
    #expect(GhosttyControlsPolicy.outcome(for: .granted) == .verified)
    #expect(GhosttyControlsPolicy.outcome(for: .denied) == .disable)
    #expect(GhosttyControlsPolicy.outcome(for: .ghosttyNotRunning) == .awaitGhostty)
    #expect(GhosttyControlsPolicy.outcome(for: .consentRequired) == .unverified)
    #expect(GhosttyControlsPolicy.outcome(for: .unknown(-1)) == .unverified)
}

@Test func firstRunOfferAppearsOnceBeforeAnyChoice() {
    #expect(GhosttyControlsPolicy.shouldOfferFirstRun(offeredBefore: false, storedPreference: nil, interactiveLaunch: true))
    #expect(!GhosttyControlsPolicy.shouldOfferFirstRun(offeredBefore: true, storedPreference: nil, interactiveLaunch: true))
    #expect(!GhosttyControlsPolicy.shouldOfferFirstRun(offeredBefore: false, storedPreference: true, interactiveLaunch: true))
    #expect(!GhosttyControlsPolicy.shouldOfferFirstRun(offeredBefore: false, storedPreference: false, interactiveLaunch: true))
    #expect(!GhosttyControlsPolicy.shouldOfferFirstRun(offeredBefore: false, storedPreference: nil, interactiveLaunch: false))
}
