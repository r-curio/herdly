import Testing
@testable import HerdlyCore

@Test(arguments: [
    (LaunchAtLoginRegistration.notRegistered, false, true, "Off", "Herdly will not open automatically."),
    (.enabled, true, true, "On", "Herdly opens automatically when you sign in to this Mac."),
    (.requiresApproval, true, true, "Approval required", "Allow Herdly in System Settings before it can open at login."),
    (.unavailable, false, false, "Unavailable", "macOS could not find Herdly's login-item registration.")
])
func launchAtLoginPresentation(
    registration: LaunchAtLoginRegistration,
    isOn: Bool,
    canChange: Bool,
    title: String,
    detail: String
) {
    let state = LaunchAtLoginState(registration: registration)
    #expect(state.isOn == isOn)
    #expect(state.canChange == canChange)
    #expect(state.statusTitle == title)
    #expect(state.detail == detail)
    #expect(state.settingsActionStatusTitle == (registration == .requiresApproval ? "Approval required" :
                                               registration == .unavailable ? "Unavailable" : nil))
}

@Test func launchAtLoginChoosesOnlyNecessaryOperations() {
    var off = LaunchAtLoginState(registration: .notRegistered)
    #expect(off.beginChange(to: false) == nil)
    #expect(off.beginChange(to: true) == .register)
    #expect(off.isChanging)
    #expect(off.beginChange(to: true) == nil)

    var enabled = LaunchAtLoginState(registration: .enabled)
    #expect(enabled.beginChange(to: true) == nil)
    #expect(enabled.beginChange(to: false) == .unregister)

    var approval = LaunchAtLoginState(registration: .requiresApproval)
    #expect(approval.beginChange(to: true) == nil)
    #expect(approval.beginChange(to: false) == .unregister)

    var unavailable = LaunchAtLoginState(registration: .unavailable)
    #expect(unavailable.beginChange(to: true) == nil)
    #expect(unavailable.beginChange(to: false) == nil)
}

@Test func failedChangeKeepsAuthoritativeRegistrationAndErrorSeparate() {
    var state = LaunchAtLoginState(registration: .notRegistered)
    #expect(state.beginChange(to: true) == .register)
    state.finishChange(registration: .requiresApproval, error: "Registration requires approval.")

    #expect(state.registration == .requiresApproval)
    #expect(state.isOn)
    #expect(!state.isChanging)
    #expect(state.operationError == "Registration requires approval.")
}

@Test func successfulChangeAndRefreshClearStaleErrors() {
    var state = LaunchAtLoginState(registration: .enabled)
    #expect(state.beginChange(to: false) == .unregister)
    state.finishChange(registration: .enabled, error: "Could not unregister.")
    #expect(state.operationError != nil)

    state.refresh(registration: .notRegistered)
    #expect(state.registration == .notRegistered)
    #expect(state.operationError == nil)
    #expect(!state.isChanging)
}

@Test func successfulChangeUsesTheStatusObservedAfterTheOperation() {
    var state = LaunchAtLoginState(registration: .notRegistered)
    #expect(state.beginChange(to: true) == .register)
    state.finishChange(registration: .enabled, error: nil)

    #expect(state.registration == .enabled)
    #expect(state.isOn)
    #expect(state.operationError == nil)
    #expect(!state.isChanging)
}

@Test(arguments: [
    (LaunchAtLoginRegistration.notRegistered, true),
    (.enabled, false),
    (.requiresApproval, false),
    (.unavailable, true)
])
func unconfiguredStartupPresentation(registration: LaunchAtLoginRegistration, opensControls: Bool) {
    let state = LaunchAtLoginState(registration: registration)
    #expect(state.shouldOpenUnconfiguredControls == opensControls)
}
