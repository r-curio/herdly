import AppKit
import CoreGraphics
import Foundation
import HerdlyCore
import os
import Security

/// The outcome of one publish. Herdly logs a failure and does nothing else with it: phone alerts
/// fail open and never touch the queue, acknowledgment, or a deadline.
enum PhoneAlertDelivery: Equatable, Sendable {
    case delivered
    case failed(String)
}

/// The one seam a phone transport plugs into (#352). ntfy is the sender today; a native iPhone app
/// on APNs replaces only this, and both can run side by side during a switch.
protocol PhoneAlertSender: Sendable {
    func send(_ message: PhoneAlertMessage) async -> PhoneAlertDelivery
}

/// Carries one HTTP request; injected so tests never reach a real server.
protocol PhoneAlertTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// An ephemeral session with bounded waits: no cookies, no cache, no indefinite retry.
struct URLSessionPhoneAlertTransport: PhoneAlertTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = NtfyPublish.timeout
        configuration.timeoutIntervalForResource = NtfyPublish.timeout + 5
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Publishes to one ntfy topic on the fixed server.
struct NtfyPhoneAlertSender: PhoneAlertSender {
    let topic: String
    let transport: any PhoneAlertTransport

    init(topic: String, transport: any PhoneAlertTransport = URLSessionPhoneAlertTransport()) {
        self.topic = topic
        self.transport = transport
    }

    func send(_ message: PhoneAlertMessage) async -> PhoneAlertDelivery {
        guard let request = NtfyPublish.request(topic: topic, message: message) else {
            return .failed("The phone topic is not a valid ntfy topic.")
        }
        do {
            let (_, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("ntfy.sh sent no HTTP response.") }
            guard (200..<300).contains(http.statusCode) else { return .failed("ntfy.sh answered \(http.statusCode).") }
            return .delivered
        } catch {
            return .failed("Couldn't reach ntfy.sh. Check your connection.")
        }
    }
}

/// Where the phone topic lives; injected so tests never touch the user's Keychain.
protocol PhoneAlertTopicStoring: Sendable {
    /// The stored topic, or nil when there is none or it is not a valid topic.
    func read() -> String?
    /// The stored topic, or a new random one saved first. Nil when it could not be saved.
    func loadOrCreate() -> String?
}

/// The phone topic, kept as a generic password in the login Keychain: it works like a password,
/// so it never goes to UserDefaults or the snapshot.
struct PhoneAlertTopicStore: PhoneAlertTopicStoring {
    let service: String
    let account: String

    init(service: String = "dev.rcurio.herdly.phone-alerts", account: String = "ntfy-topic") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The stored topic, or nil when there is none or it is not a valid topic.
    func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let topic = String(data: data, encoding: .utf8),
              NtfyPublish.isValidTopic(topic) else { return nil }
        return topic
    }

    /// Replaces the stored topic. False when the Keychain refused it.
    func save(_ topic: String) -> Bool {
        let data = Data(topic.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Herdly phone alert topic"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// The stored topic, or a new random one saved first. Nil when the Keychain refused to save it.
    func loadOrCreate() -> String? {
        if let topic = read() { return topic }
        var generator = SystemRandomNumberGenerator()
        let topic = NtfyPublish.newTopic(using: &generator)
        return save(topic) ? topic : nil
    }
}

/// Settings › Notifications › Phone and the arrival hook. Owned by `Companion`; it reads the queue
/// only through the candidates it is handed, and every publish runs off the main actor.
@MainActor
final class PhoneAlerts: ObservableObject {
    static let enabledKey = "phoneAlertsEnabled"
    private nonisolated static let log = Logger(subsystem: "dev.rcurio.herdly", category: "phone-alerts")

    @Published private(set) var setting: PhoneAlertSetting
    /// Shown in the Topic row while the switch is on; nil until the Keychain gave one.
    @Published private(set) var topic: String?
    /// The orange line under the Phone card: the last test failure, or a Keychain failure.
    @Published private(set) var problem: String?
    @Published private(set) var testInFlight = false

    private(set) var ledger = PhoneAlertLedger()
    private let defaults: UserDefaults
    private let store: any PhoneAlertTopicStoring
    private let makeSender: @Sendable (String) -> any PhoneAlertSender
    private let idleSeconds: () -> Double?

    init(defaults: UserDefaults = .standard, store: any PhoneAlertTopicStoring = PhoneAlertTopicStore(),
         makeSender: @escaping @Sendable (String) -> any PhoneAlertSender = { NtfyPhoneAlertSender(topic: $0) },
         idleSeconds: @escaping () -> Double? = PhoneAlerts.systemIdleSeconds) {
        self.defaults = defaults
        self.store = store
        self.makeSender = makeSender
        self.idleSeconds = idleSeconds
        setting = defaults.bool(forKey: Self.enabledKey) ? .on : .off
    }

    /// Seconds since the last keyboard, pointer, or other input event in this login session. Needs
    /// no permission. `kCGAnyInputEventType` (~0) is required: `.null` measures null events and on
    /// macOS 26.5 read days while the user was typing.
    nonisolated static func systemIdleSeconds() -> Double? {
        guard let anyInput = CGEventType(rawValue: ~0) else { return nil }
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    var enabled: Bool { setting == .on }

    func setEnabled(_ enabled: Bool) {
        problem = nil
        if enabled {
            guard let topic = topic ?? store.loadOrCreate() else {
                problem = "Couldn't save the phone topic in the Keychain."
                Self.log.error("Phone alerts not enabled: the Keychain refused the topic")
                return
            }
            self.topic = topic
        }
        setting = enabled ? .on : .off
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    /// Loads the topic for the Topic row, once, when Settings shows it.
    func loadTopicIfNeeded() {
        guard enabled, topic == nil else { return }
        topic = store.read()
    }

    func copyTopic() {
        guard let topic else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(topic, forType: .string)
    }

    /// Considers each newly queued item once, at arrival, and publishes the ones that alert. Never
    /// changes the queue; a failure is logged and dropped. Returns the messages handed to the sender.
    @discardableResult
    func arrived(_ candidates: [PhoneAlertCandidate]) -> [PhoneAlertMessage] {
        guard !candidates.isEmpty else { return [] }
        // The idle reading is taken only when the switch is on; the ledger records every arrival
        // either way, so turning the switch on later never sends an item that already arrived.
        let idle = enabled ? idleSeconds() : nil
        let messages = ledger.consider(candidates, idleSeconds: idle, setting: setting)
        guard !messages.isEmpty else { return [] }
        guard let topic = topic ?? store.read() else {
            Self.log.error("Phone alert skipped: no topic in the Keychain")
            return []
        }
        if self.topic != topic { self.topic = topic }
        let sender = makeSender(topic)
        for message in messages {
            Task.detached(priority: .utility) {
                if case let .failed(reason) = await sender.send(message) {
                    Self.log.error("Phone alert not delivered: \(reason, privacy: .public)")
                }
            }
        }
        return messages
    }

    /// "Send Test to Phone": one test alert; a failure shows under the Phone card.
    func sendTest() {
        guard enabled, !testInFlight else { return }
        guard let topic = topic ?? store.loadOrCreate() else {
            problem = "Couldn't read the phone topic from the Keychain."
            return
        }
        self.topic = topic
        problem = nil
        testInFlight = true
        let sender = makeSender(topic)
        Task { [weak self] in
            let delivery = await Task.detached(priority: .userInitiated) { await sender.send(.test) }.value
            guard let self else { return }
            self.testInFlight = false
            if case let .failed(reason) = delivery {
                self.problem = reason
                Self.log.error("Phone test alert not delivered: \(reason, privacy: .public)")
            }
        }
    }
}
