import Foundation
import Testing
@testable import HerdlyApp
@testable import HerdlyCore

@MainActor
private final class LaunchAtLoginServiceStub: LaunchAtLoginServicing {
    private var registrationValue: LaunchAtLoginRegistration
    var resultRegistration: LaunchAtLoginRegistration?
    var error: Error?
    private(set) var operations: [LaunchAtLoginOperation] = []
    private(set) var registrationReads = 0
    private(set) var openedSystemSettings = false

    init(registration: LaunchAtLoginRegistration) {
        registrationValue = registration
    }

    var registration: LaunchAtLoginRegistration {
        registrationReads += 1
        return registrationValue
    }

    func perform(_ operation: LaunchAtLoginOperation) throws {
        operations.append(operation)
        if let resultRegistration { registrationValue = resultRegistration }
        if let error { throw error }
    }

    func openSystemSettings() {
        openedSystemSettings = true
    }
}

private struct TestFailure: LocalizedError {
    var errorDescription: String? { "Test failure" }
}

@MainActor
@Test func coordinatorRefreshReadsTheService() {
    let service = LaunchAtLoginServiceStub(registration: .enabled)
    let coordinator = LaunchAtLoginCoordinator(service: service)

    coordinator.refresh()

    #expect(coordinator.state.registration == .enabled)
    #expect(service.registrationReads == 1)
}

@MainActor
@Test(arguments: [
    (LaunchAtLoginRegistration.notRegistered, true),
    (.enabled, false),
    (.requiresApproval, false)
])
func coordinatorPerformsThenReconcilesWithASecondStatusRead(
    initial: LaunchAtLoginRegistration,
    enabled: Bool
) {
    let service = LaunchAtLoginServiceStub(registration: initial)
    service.resultRegistration = enabled ? .enabled : .notRegistered
    let coordinator = LaunchAtLoginCoordinator(service: service,
                                               state: LaunchAtLoginState(registration: initial))

    coordinator.setEnabled(enabled)

    #expect(service.operations == [enabled ? .register : .unregister])
    #expect(service.registrationReads == 1)
    #expect(coordinator.state.registration == service.resultRegistration)
    #expect(coordinator.state.operationError == nil)
}

@MainActor
@Test(arguments: [
    (LaunchAtLoginRegistration.notRegistered, true, LaunchAtLoginRegistration.requiresApproval, LaunchAtLoginOperation.register),
    (.notFound, true, .enabled, .register),
    (.enabled, false, .enabled, .unregister)
])
func coordinatorReconcilesAuthoritativeStatusAfterAThrownOperation(
    initial: LaunchAtLoginRegistration,
    enabled: Bool,
    observed: LaunchAtLoginRegistration,
    operation: LaunchAtLoginOperation
) {
    let service = LaunchAtLoginServiceStub(registration: initial)
    service.resultRegistration = observed
    service.error = TestFailure()
    let coordinator = LaunchAtLoginCoordinator(service: service,
                                               state: LaunchAtLoginState(registration: initial))

    coordinator.setEnabled(enabled)

    #expect(service.operations == [operation])
    #expect(service.registrationReads == 1)
    #expect(coordinator.state.registration == observed)
    #expect(coordinator.state.operationError?.contains("Test failure") == true)
}

@MainActor
@Test(arguments: [
    (LaunchAtLoginRegistration.notRegistered, false),
    (.notFound, false),
    (.enabled, true),
    (.requiresApproval, true),
    (.unavailable, true)
])
func coordinatorSkipsIdempotentOrUnavailableChanges(
    initial: LaunchAtLoginRegistration,
    enabled: Bool
) {
    let service = LaunchAtLoginServiceStub(registration: initial)
    let coordinator = LaunchAtLoginCoordinator(service: service,
                                               state: LaunchAtLoginState(registration: initial))

    coordinator.setEnabled(enabled)

    #expect(service.operations.isEmpty)
    #expect(service.registrationReads == 0)
}

@MainActor
@Test func coordinatorDelegatesSystemSettingsNavigation() {
    let service = LaunchAtLoginServiceStub(registration: .requiresApproval)
    let coordinator = LaunchAtLoginCoordinator(service: service)

    coordinator.openSystemSettings()

    #expect(service.openedSystemSettings)
}
