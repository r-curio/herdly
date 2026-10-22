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
    let topic: NtfyTopic
    let transport: any PhoneAlertTransport

    init(topic: NtfyTopic, transport: any PhoneAlertTransport = URLSessionPhoneAlertTransport()) {
        self.topic = topic
        self.transport = transport
    }

    func send(_ message: PhoneAlertMessage) async -> PhoneAlertDelivery {
        guard let request = NtfyPublish.request(topic: topic, message: message) else {
            return .failed("Couldn't prepare the alert for ntfy.sh.")
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

/// Where the phone topic lives; injected so tests never touch the user's Keychain. Both calls may
/// block (a Keychain access prompt), so `PhoneAlerts` makes them off the main actor only.
protocol PhoneAlertTopicStoring: Sendable {
    /// The stored topic, or nil when there is none or it is not a valid topic.
    func read() -> NtfyTopic?
    /// The stored topic, or a new random one saved first. Nil when it could not be saved.
    func loadOrCreate() -> NtfyTopic?
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

    func read() -> NtfyTopic? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let name = String(data: data, encoding: .utf8) else { return nil }
        return NtfyTopic(name)
    }

    /// Replaces the stored topic. False when the Keychain refused it.
    private func save(_ topic: NtfyTopic) -> Bool {
        let data = Data(topic.name.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Herdly phone alert topic"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func loadOrCreate() -> NtfyTopic? {
        if let topic = read() { return topic }
        var generator = SystemRandomNumberGenerator()
        let topic = NtfyTopic.random(using: &generator)
        return save(topic) ? topic : nil
    }
}

/// Where the switch is remembered; injected so tests leave no preferences behind.
protocol PhoneAlertSwitchStoring {
    func load() -> PhoneAlertSetting
    func save(_ setting: PhoneAlertSetting)
}

struct UserDefaultsPhoneAlertSwitch: PhoneAlertSwitchStoring {
    static let key = "phoneAlertsEnabled"
    func load() -> PhoneAlertSetting { UserDefaults.standard.bool(forKey: Self.key) ? .on : .off }
    func save(_ setting: PhoneAlertSetting) { UserDefaults.standard.set(setting == .on, forKey: Self.key) }
}

/// The topic as the main actor knows it. Loading happens off the main actor; until it finishes,
/// arrivals are recorded but not sent.
enum PhoneAlertTopicState: Equatable, Sendable {
    case notLoaded
    case loading
    case ready(NtfyTopic)
    case unavailable
}

/// What `arrived` handed to the sender: the messages, and the detached publish to await in tests.
struct PhoneAlertDispatch {
    let messages: [PhoneAlertMessage]
    let deliveries: Task<[PhoneAlertDelivery], Never>?

    static let none = PhoneAlertDispatch(messages: [], deliveries: nil)
}

/// Settings › Notifications › Phone and the arrival hook. Owned by `Companion`; it reads the queue
/// only through the candidates it is handed. Keychain reads and every publish run off the main
/// actor, so a Keychain prompt or a slow network never stalls a scan.
@MainActor
final class PhoneAlerts: ObservableObject {
    private nonisolated static let log = Logger(subsystem: "dev.rcurio.herdly", category: "phone-alerts")

    @Published private(set) var setting: PhoneAlertSetting
    @Published private(set) var topicState: PhoneAlertTopicState = .notLoaded
    /// The orange line under the Phone card: the last test failure, or a Keychain failure.
    @Published private(set) var problem: String?
    @Published private(set) var testInFlight = false

    private(set) var ledger = PhoneAlertLedger()
    private let switchStore: any PhoneAlertSwitchStoring
    private let store: any PhoneAlertTopicStoring
    private let makeSender: @Sendable (NtfyTopic) -> any PhoneAlertSender
    private let idleSeconds: () -> Double?

    init(switchStore: any PhoneAlertSwitchStoring = UserDefaultsPhoneAlertSwitch(),
         store: any PhoneAlertTopicStoring = PhoneAlertTopicStore(),
         makeSender: @escaping @Sendable (NtfyTopic) -> any PhoneAlertSender = { NtfyPhoneAlertSender(topic: $0) },
         idleSeconds: @escaping () -> Double? = PhoneAlerts.systemIdleSeconds) {
        self.switchStore = switchStore
        self.store = store
        self.makeSender = makeSender
        self.idleSeconds = idleSeconds
        setting = switchStore.load()
    }

    /// Seconds since the last keyboard, pointer, or other input event in this login session. Needs
    /// no permission. The event type must be `kCGAnyInputEventType` (~0): `.null` measures only
    /// null events, and on macOS 26.5 it read about a week while the user was typing.
    nonisolated static func systemIdleSeconds() -> Double? {
        let anyInput = CGEventType(rawValue: ~0)!
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    var enabled: Bool { setting == .on }
    var topic: NtfyTopic? { if case let .ready(topic) = topicState { topic } else { nil } }

    /// At launch: with the switch on, read the stored topic off the main actor.
    @discardableResult
    func start() -> Task<Void, Never>? {
        guard enabled, topic == nil else { return nil }
        return loadTopic(creating: false)
    }

    /// Turning on creates the topic on first use, off the main actor. If the Keychain refuses it the
    /// switch goes back off with the problem line.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Task<Void, Never>? {
        problem = nil
        setting = enabled ? .on : .off
        switchStore.save(setting)
        guard enabled, topic == nil else { return nil }
        return loadTopic(creating: true)
    }

    private func loadTopic(creating: Bool) -> Task<Void, Never>? {
        guard topicState != .loading else { return nil }
        topicState = .loading
        let store = store
        return Task { [weak self] in
            let topic = await Task.detached(priority: .utility) {
                creating ? store.loadOrCreate() : store.read()
            }.value
            guard let self else { return }
            if let topic {
                self.topicState = .ready(topic)
                return
            }
            self.topicState = .unavailable
            Self.log.error("Phone alert topic unavailable from the Keychain")
            guard self.enabled else { return }
            if creating {
                self.setting = .off
                self.switchStore.save(.off)
                self.problem = "Couldn't save the phone topic in the Keychain."
            } else {
                self.problem = "Couldn't read the phone topic from the Keychain."
            }
        }
    }

    func copyTopic() {
        guard let topic else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(topic.name, forType: .string)
    }

    /// Considers each newly queued item once, at arrival, and publishes the ones that alert. Never
    /// changes the queue and never blocks: with no topic loaded yet the alert is recorded, logged,
    /// and skipped. A failed publish is logged and dropped.
    @discardableResult
    func arrived(_ candidates: [PhoneAlertCandidate]) -> PhoneAlertDispatch {
        guard !candidates.isEmpty else { return .none }
        // The ledger records every arrival, sent or not, so turning the switch on later or going
        // idle later never sends an item that already arrived.
        let idle = enabled ? idleSeconds() : nil
        let messages = ledger.consider(candidates, idleSeconds: idle, setting: setting)
        guard !messages.isEmpty else { return .none }
        guard let topic else {
            Self.log.error("Phone alert skipped: the topic is not loaded")
            return .none
        }
        let sender = makeSender(topic)
        let deliveries = Task.detached(priority: .utility) { () -> [PhoneAlertDelivery] in
            var results: [PhoneAlertDelivery] = []
            for message in messages {
                let delivery = await sender.send(message)
                if case let .failed(reason) = delivery {
                    Self.log.error("Phone alert not delivered: \(reason, privacy: .public)")
                }
                results.append(delivery)
            }
            return results
        }
        return PhoneAlertDispatch(messages: messages, deliveries: deliveries)
    }

    /// "Send Test to Phone": one test alert; a failure shows under the Phone card.
    @discardableResult
    func sendTest() -> Task<Void, Never>? {
        guard enabled, !testInFlight else { return nil }
        guard let topic else {
            problem = "The phone topic isn't ready yet. Try again in a moment."
            return nil
        }
        problem = nil
        testInFlight = true
        let sender = makeSender(topic)
        return Task { [weak self] in
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
