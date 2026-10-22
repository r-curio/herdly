import Foundation
import Testing
@testable import HerdlyApp
@testable import HerdlyCore

// #352: a notify-only phone alert through ntfy when an approval, a question, or a completion arrives
// while the Mac has been idle for 2 minutes. Once per item, at arrival; restored items stay silent;
// the text carries the agent, the kind, and the project folder only.

private let launchedAt = 1_000.0
private let codexCLI = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "codex-1", surface: .cli)
private let codexDesktop = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "codex-2", surface: .desktop)
private let claude = AgentSessionIdentity(source: .claude, sourceScope: "/Users/me/.claude", session: "claude-1", surface: .cli)
private let codexWorking = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "codex-3", surface: .cli)

private let secretCommand = "rm -rf /Users/me/Secrets/payroll"
private let secretReason = "Needs to delete the payroll exports"
private let secretQuestion = "Which bank account should I wire the money to?"
private let secretOption = "Account 4417-PRIVATE"
private let secretPath = "/Users/me/Clients/Acme/herdly"

/// Queue rows built the way Herdly builds them, one of each kind that alerts, plus running work.
private func rows(arrivedAt: Double = launchedAt + 5, uncertain: Bool = false) -> [AgentAttentionItem] {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: codexCLI, turn: "t1", call: "a1", arrivedAt: arrivedAt,
                                        details: ApprovalDetails(taskName: "Fix payroll", project: secretPath,
                                                                 action: "Run command", command: secretCommand,
                                                                 reason: secretReason))), now: arrivedAt)
    queue.apply(.question(AgentQuestion(session: claude, turn: "t2", call: "q1", arrivedAt: arrivedAt,
                                        prompts: [QuestionPrompt(header: "Bank", question: secretQuestion,
                                                                 options: [secretOption, "Other account"])])), now: arrivedAt)
    queue.apply(.outcome(AgentOutcome(session: codexDesktop, turn: "t3", status: .finished, arrivedAt: arrivedAt,
                                      uncertain: uncertain)), now: arrivedAt)
    queue.apply(.running(AgentRunning(session: codexWorking, turn: "t4", arrivedAt: arrivedAt)), now: arrivedAt)
    return queue.items(at: arrivedAt)
}

private func candidates(_ items: [AgentAttentionItem]) -> [PhoneAlertCandidate] {
    items.compactMap { item in
        PhoneAlertCandidate(item, project: item.approval?.details?.project ?? "/Users/me/src/herdly", launchedAt: launchedAt)
    }
}

// MARK: Which items alert, and when

@Test func eachKindAlertsOnceWhenIdleAtTheThreshold() {
    var ledger = PhoneAlertLedger()
    let messages = ledger.consider(candidates(rows()), idleSeconds: 120, setting: .on)
    #expect(messages.map(\.title) == ["Codex needs permission", "Claude needs an answer", "Codex finished"])
    #expect(messages.map(\.body) == ["herdly — decide on your Mac", "herdly", "herdly"])
    #expect(messages.map(\.priority) == [.high, .high, .standard])
}

@Test func noKindAlertsJustUnderTheIdleThreshold() {
    var ledger = PhoneAlertLedger()
    #expect(ledger.consider(candidates(rows()), idleSeconds: 119.9, setting: .on).isEmpty)
    #expect(ledger.consider(candidates(rows()), idleSeconds: 3, setting: .on).isEmpty)
}

@Test func anItemThatArrivedWhileActiveIsNotSentWhenTheUserLaterGoesIdle() {
    var ledger = PhoneAlertLedger()
    _ = ledger.consider(candidates(rows()), idleSeconds: 10, setting: .on)
    #expect(ledger.consider(candidates(rows()), idleSeconds: 600, setting: .on).isEmpty)
}

@Test func anUnknownIdleReadingSendsNothing() {
    var ledger = PhoneAlertLedger()
    #expect(ledger.consider(candidates(rows()), idleSeconds: nil, setting: .on).isEmpty)
    #expect(ledger.consider(candidates(rows()), idleSeconds: .nan, setting: .on).isEmpty)
}

@Test func runningWorkAndOtherRowKindsNeverAlert() {
    #expect(PhoneAlertKind(.running) == nil)
    #expect(PhoneAlertKind(.waiting) == nil)
    #expect(PhoneAlertKind(.statusUnavailable) == nil)
    let running = rows().filter { $0.running != nil }
    #expect(running.count == 1)
    #expect(candidates(running).isEmpty)
}

@Test func aHandedBackApprovalAndAnEarlierResultStillCountAsTheirKind() {
    #expect(PhoneAlertKind(.handedBackApproval) == .approval)
    #expect(PhoneAlertKind(.earlierOutcome) == .completion)
}

@Test func duplicateAndReorderedArrivalsSendOnce() {
    var ledger = PhoneAlertLedger()
    let all = candidates(rows())
    #expect(ledger.consider(all + all, idleSeconds: 300, setting: .on).count == 3)
    #expect(ledger.consider(all.reversed(), idleSeconds: 300, setting: .on).isEmpty)
    #expect(ledger.consider(all, idleSeconds: 300, setting: .on).isEmpty)
}

@Test func theLedgerStaysBoundedAndForgetsTheOldestFirst() {
    var ledger = PhoneAlertLedger(capacity: 2)
    let make = { (call: String) in
        PhoneAlertCandidate(id: .question(AgentCallIdentity(session: claude, turn: "t", call: call)),
                            kind: .question, source: .claude, project: nil, arrival: .fresh)
    }
    _ = ledger.consider([make("1"), make("2"), make("3")], idleSeconds: 300, setting: .on)
    #expect(ledger.count == 2)
    #expect(!ledger.contains(make("1").id))
    #expect(ledger.contains(make("3").id))
}

@Test func restoredPreLaunchAndUncertainItemsStaySilent() {
    var ledger = PhoneAlertLedger()
    let beforeLaunch = candidates(rows(arrivedAt: launchedAt - 1))
    #expect(beforeLaunch.allSatisfy { $0.arrival == .restored })
    #expect(ledger.consider(beforeLaunch, idleSeconds: 3_600, setting: .on).isEmpty)

    var other = PhoneAlertLedger()
    let uncertain = candidates(rows(uncertain: true)).filter { $0.kind == .completion }
    #expect(uncertain.map(\.arrival) == [.restored])
    #expect(other.consider(uncertain, idleSeconds: 3_600, setting: .on).isEmpty)
}

@Test func theSwitchOffSendsNothingAndTurningItOnLaterDoesNotReplay() {
    var ledger = PhoneAlertLedger()
    #expect(ledger.consider(candidates(rows()), idleSeconds: 3_600, setting: .off).isEmpty)
    #expect(ledger.consider(candidates(rows()), idleSeconds: 3_600, setting: .on).isEmpty)
}

// MARK: Text

@Test func theTextNeverCarriesPromptsCommandsOptionsOrPaths() {
    var ledger = PhoneAlertLedger()
    let messages = ledger.consider(candidates(rows()), idleSeconds: 300, setting: .on)
    #expect(messages.count == 3)
    let text = messages.flatMap { [$0.title, $0.body] + $0.tags }.joined(separator: "\n")
    for secret in [secretCommand, secretReason, secretQuestion, secretOption, secretPath, "Fix payroll",
                   "Acme", "Clients", "/Users", "payroll", "Bank"] {
        #expect(!text.contains(secret), "phone text leaked \(secret)")
    }
    #expect(messages.first?.body == "herdly — decide on your Mac")
}

@Test func theProjectIsTheFolderNameOnly() {
    #expect(PhoneAlertPolicy.projectName("/Users/me/src/herdly/") == "herdly")
    #expect(PhoneAlertPolicy.projectName("herdly") == "herdly")
    #expect(PhoneAlertPolicy.projectName("/") == nil)
    #expect(PhoneAlertPolicy.projectName("~") == nil)
    #expect(PhoneAlertPolicy.projectName("  ") == nil)
    #expect(PhoneAlertPolicy.projectName("/x/bad\u{7}name\n") == "badname")
    #expect(PhoneAlertPolicy.projectName("/x/" + String(repeating: "a", count: 100))?.count == 64)
}

@Test func withoutAProjectTheBodySaysWhereToLook() {
    #expect(PhoneAlertPolicy.text(kind: .approval, source: .claude, project: nil)
        == PhoneAlertMessage(title: "Claude needs permission", body: "Decide on your Mac", priority: .high, tags: ["lock"]))
    #expect(PhoneAlertPolicy.text(kind: .question, source: .codex, project: nil).body == "Answer on your Mac")
    #expect(PhoneAlertPolicy.text(kind: .completion, source: .codex, project: nil).body == "The result is on your Mac")
}

// MARK: ntfy request

@Test func theNtfyRequestIsAJSONPostToTheServerRoot() throws {
    let message = PhoneAlertPolicy.text(kind: .approval, source: .codex, project: "café")
    let request = try #require(NtfyPublish.request(topic: "herdly-abc234", message: message))
    #expect(request.url?.absoluteString == "https://ntfy.sh/")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.timeoutInterval == 10)
    // No header carries text: the title and body travel as UTF-8 JSON.
    #expect(request.value(forHTTPHeaderField: "Title") == nil)
    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["topic"] as? String == "herdly-abc234")
    #expect(json["title"] as? String == "Codex needs permission")
    #expect(json["message"] as? String == "café — decide on your Mac")
    #expect(json["priority"] as? Int == 4)
    #expect(json["tags"] as? [String] == ["lock"])
    #expect(Set(json.keys) == ["topic", "title", "message", "priority", "tags"])
}

@Test func anInvalidTopicBuildsNoRequest() {
    for topic in ["", "has space", "slash/topic", "ünïcode", String(repeating: "a", count: 65)] {
        #expect(NtfyPublish.request(topic: topic, message: .test) == nil)
    }
}

@Test func aNewTopicIsPrivateAndValid() {
    var generator = SystemRandomNumberGenerator()
    let first = NtfyPublish.newTopic(using: &generator)
    let second = NtfyPublish.newTopic(using: &generator)
    #expect(first.hasPrefix("herdly-"))
    #expect(first.count == 27)
    #expect(NtfyPublish.isValidTopic(first))
    #expect(first != second)
}

// MARK: Sender and controller (HerdlyApp)

private final class RecordingTransport: PhoneAlertTransport, @unchecked Sendable {
    // Test-only: one test drives it from one task at a time, guarded by the lock anyway.
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    let status: Int?

    init(status: Int?) { self.status = status }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { recorded.append(request) }
        guard let status else { throw URLError(.notConnectedToInternet) }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Test func theNtfySenderPostsThroughItsTransport() async {
    let transport = RecordingTransport(status: 200)
    let sender = NtfyPhoneAlertSender(topic: "herdly-test", transport: transport)
    #expect(await sender.send(.test) == .delivered)
    #expect(transport.requests.count == 1)
    #expect(transport.requests.first?.url?.absoluteString == "https://ntfy.sh/")
    #expect(transport.requests.first?.httpMethod == "POST")
}

@Test func theNtfySenderReportsFailuresWithoutRetrying() async {
    let offline = RecordingTransport(status: nil)
    #expect(await NtfyPhoneAlertSender(topic: "herdly-test", transport: offline).send(.test)
        == .failed("Couldn't reach ntfy.sh. Check your connection."))
    #expect(offline.requests.count == 1)
    let limited = RecordingTransport(status: 429)
    #expect(await NtfyPhoneAlertSender(topic: "herdly-test", transport: limited).send(.test) == .failed("ntfy.sh answered 429."))
    #expect(limited.requests.count == 1)
    let invalid = RecordingTransport(status: 200)
    #expect(await NtfyPhoneAlertSender(topic: "bad topic", transport: invalid).send(.test)
        == .failed("The phone topic is not a valid ntfy topic."))
    #expect(invalid.requests.isEmpty)
}

private struct FixedTopicStore: PhoneAlertTopicStoring {
    let topic: String?
    func read() -> String? { topic }
    func loadOrCreate() -> String? { topic }
}

private struct FailingSender: PhoneAlertSender {
    func send(_ message: PhoneAlertMessage) async -> PhoneAlertDelivery { .failed("offline") }
}

@MainActor
private func controller(topic: String? = "herdly-test", idle: Double? = 600) -> PhoneAlerts {
    let defaults = UserDefaults(suiteName: "PhoneAlertTests-\(UUID().uuidString)")!
    return PhoneAlerts(defaults: defaults, store: FixedTopicStore(topic: topic),
                       makeSender: { _ in FailingSender() }, idleSeconds: { idle })
}

@MainActor
@Test func phoneAlertsAreOffByDefaultAndPersistTheSwitch() {
    let suite = "PhoneAlertTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let alerts = PhoneAlerts(defaults: defaults, store: FixedTopicStore(topic: "herdly-test"),
                             makeSender: { _ in FailingSender() }, idleSeconds: { 600 })
    #expect(alerts.setting == .off)
    #expect(alerts.arrived(candidates(rows())).isEmpty)
    alerts.setEnabled(true)
    #expect(alerts.topic == "herdly-test")
    #expect(PhoneAlerts(defaults: defaults, store: FixedTopicStore(topic: nil),
                        makeSender: { _ in FailingSender() }, idleSeconds: { 600 }).setting == .on)
}

@MainActor
@Test func aKeychainFailureKeepsTheSwitchOffAndSaysSo() {
    let alerts = controller(topic: nil)
    alerts.setEnabled(true)
    #expect(alerts.setting == .off)
    #expect(alerts.problem == "Couldn't save the phone topic in the Keychain.")
}

@MainActor
@Test func aSenderFailureLeavesTheQueueAndLedgerAsTheyWere() async {
    let alerts = controller()
    alerts.setEnabled(true)
    var queue = AgentAttentionQueue()
    for item in rows() {
        if let approval = item.approval { queue.apply(.approval(approval), now: item.arrivedAt) }
        if let question = item.question { queue.apply(.question(question), now: item.arrivedAt) }
        if let outcome = item.outcome { queue.apply(.outcome(outcome), now: item.arrivedAt) }
    }
    let before = queue
    let items = queue.items(at: launchedAt + 5)
    #expect(alerts.arrived(candidates(items)).count == 3)
    // The failed publishes run detached; give them a turn, then nothing has changed or retried.
    for _ in 0..<5 { await Task.yield() }
    #expect(queue == before)
    #expect(queue.items(at: launchedAt + 5) == items)
    #expect(alerts.ledger.count == 3)
    #expect(alerts.problem == nil)
    #expect(alerts.arrived(candidates(items)).isEmpty)
}

@MainActor
@Test func aFailedTestShowsTheProblemLine() async {
    let alerts = controller()
    alerts.setEnabled(true)
    alerts.sendTest()
    for _ in 0..<200 where alerts.testInFlight { try? await Task.sleep(nanoseconds: 1_000_000) }
    #expect(!alerts.testInFlight)
    #expect(alerts.problem == "offline")
}
