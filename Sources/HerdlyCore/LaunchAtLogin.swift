public enum LaunchAtLoginRegistration: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case unavailable

    public var isOptedIn: Bool {
        self == .enabled || self == .requiresApproval
    }
}

public enum LaunchAtLoginOperation: Equatable, Sendable {
    case register
    case unregister
}

/// The platform-neutral state behind the launch-at-login setting. The app supplies every observed
/// registration value from ServiceManagement; this type never persists a second preference.
public struct LaunchAtLoginState: Equatable, Sendable {
    public private(set) var registration: LaunchAtLoginRegistration
    public private(set) var isChanging = false
    public private(set) var operationError: String?

    public init(registration: LaunchAtLoginRegistration = .notRegistered) {
        self.registration = registration
    }

    public var isOn: Bool { registration.isOptedIn }
    public var canChange: Bool { registration != .unavailable && !isChanging }
    public var shouldOpenUnconfiguredControls: Bool { !registration.isOptedIn }
    public var settingsActionStatusTitle: String? {
        switch registration {
        case .requiresApproval: "Approval required"
        case .unavailable: "Unavailable"
        case .notRegistered, .enabled: nil
        }
    }

    public var statusTitle: String {
        switch registration {
        case .notRegistered: "Off"
        case .enabled: "On"
        case .requiresApproval: "Approval required"
        case .unavailable: "Unavailable"
        }
    }

    public var detail: String {
        switch registration {
        case .notRegistered: "Herdly will not open automatically."
        case .enabled: "Herdly opens automatically when you sign in to this Mac."
        case .requiresApproval: "Allow Herdly in System Settings before it can open at login."
        case .unavailable: "macOS could not find Herdly's login-item registration."
        }
    }

    /// Returns the one system operation needed for the requested value, or nil for an idempotent
    /// or unavailable request. Starting any valid request clears an older error immediately.
    public mutating func beginChange(to enabled: Bool) -> LaunchAtLoginOperation? {
        guard canChange else { return nil }
        let operation: LaunchAtLoginOperation?
        if enabled {
            operation = registration == .notRegistered ? .register : nil
        } else {
            operation = registration.isOptedIn ? .unregister : nil
        }
        operationError = nil
        if operation != nil { isChanging = true }
        return operation
    }

    /// Reconciles an attempted operation with the status macOS reports afterwards, even when the
    /// operation threw. An error never substitutes for or implies a registration state.
    public mutating func finishChange(registration: LaunchAtLoginRegistration, error: String?) {
        self.registration = registration
        operationError = error
        isChanging = false
    }

    /// Re-reading system state clears an old operation error and never infers state from it.
    public mutating func refresh(registration: LaunchAtLoginRegistration) {
        self.registration = registration
        operationError = nil
        isChanging = false
    }
}
