import ServiceManagement
import HerdlyCore

@MainActor
protocol LaunchAtLoginServicing {
    var registration: LaunchAtLoginRegistration { get }
    func perform(_ operation: LaunchAtLoginOperation) throws
    func openSystemSettings()
}

@MainActor
final class LaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var registration: LaunchAtLoginRegistration {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unavailable
        }
    }

    func perform(_ operation: LaunchAtLoginOperation) throws {
        switch operation {
        case .register: try service.register()
        case .unregister: try service.unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Owns the ServiceManagement interaction so its read-after-write and failure behavior can be
/// checked with an inert service. The real adapter remains the only implementation that calls macOS.
@MainActor
final class LaunchAtLoginCoordinator {
    private let service: any LaunchAtLoginServicing
    private(set) var state: LaunchAtLoginState

    init(service: any LaunchAtLoginServicing, state: LaunchAtLoginState = LaunchAtLoginState()) {
        self.service = service
        self.state = state
    }

    func refresh() {
        state.refresh(registration: service.registration)
    }

    func setEnabled(_ enabled: Bool) {
        guard let operation = state.beginChange(to: enabled) else { return }
        var message: String?
        do {
            try service.perform(operation)
        } catch {
            let action = operation == .register ? "turn on" : "turn off"
            message = "Herdly couldn't \(action) launch at login. macOS reports: \(error.localizedDescription)"
        }
        state.finishChange(registration: service.registration, error: message)
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
