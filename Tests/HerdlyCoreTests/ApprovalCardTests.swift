import Foundation
import Testing
@testable import HerdlyCore

private let claude = AgentSessionIdentity(source: .claude, sourceScope: "/claude", session: "s1", surface: .cli)
private let codexCLI = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "s2", surface: .cli)
private let codexDesktop = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "s3", surface: .desktop)

@Test func theLastFiveSecondsOfAnApprovalAreUrgent() throws {
    // A 30-second window received at 100: 6 seconds left is not urgent, 5 is.
    let six = try #require(ApprovalCountdown(arrivedAt: 100, expiresAt: 130, now: 124))
    #expect(six.seconds == 6 && !six.isUrgent)
    let fivePointOne = try #require(ApprovalCountdown(arrivedAt: 100, expiresAt: 130, now: 124.9))
    // 5.1 seconds rounds up to 6: still not urgent.
    #expect(fivePointOne.seconds == 6 && !fivePointOne.isUrgent)
    let five = try #require(ApprovalCountdown(arrivedAt: 100, expiresAt: 130, now: 125))
    #expect(five.seconds == 5 && five.isUrgent)
    let one = try #require(ApprovalCountdown(arrivedAt: 100, expiresAt: 130, now: 129.9))
    #expect(one.isUrgent)
    let full = try #require(ApprovalCountdown(arrivedAt: 100, expiresAt: 130, now: 100))
    #expect(!full.isUrgent)
}

@Test func aClaudeApprovalReadsAsTheSameCardBodyFromItsOwnDetails() {
    let approval = AgentApproval(session: claude, turn: "t1", call: "toolu_1", arrivedAt: 100,
                                 details: ApprovalDetails(action: "Bash", command: "swift test --parallel"))
    let card = SpotlightRequest(approval: approval, contextDirectory: "/Users/me/code/herdly", home: "/Users/me")
    #expect(card.ask == nil)
    #expect(card.action == "Bash")
    #expect(card.command == "swift test --parallel")
    // Claude names no project in its request; the session's own directory places the card.
    #expect(card.directory?.display == "~/code/herdly")
    #expect(card.directory?.full == "/Users/me/code/herdly")
    // The card reads the request's own deadline; nothing restarts it.
    #expect(card.arrivedAt == 100 && card.expiresAt == 130)
    #expect(card.fullRequest == nil)
}

@Test func anApprovalCardKeepsItsRequestsAskAndRawTextAndNamesWhoLeftTheCommandOut() {
    let file = AgentApproval(session: claude, turn: "t1", call: "toolu_2", arrivedAt: 0,
                             details: ApprovalDetails(action: "Edit file", command: "/repo/a.swift",
                                                      longText: "- old\n+ new", commandLabel: "path"))
    let fileCard = SpotlightRequest(approval: file, contextDirectory: nil, home: "/Users/me")
    // A diff preview is not JSON the card already shows, so it stays behind Show full request.
    #expect(fileCard.fullRequest == "- old\n+ new")
    #expect(fileCard.directory == nil)

    let asked = AgentApproval(session: codexCLI, turn: "t1", call: "c1", arrivedAt: 0,
                              details: ApprovalDetails(project: "/Users/me/x", action: "Run", command: nil,
                                                       reason: "  Fetch the remote  "))
    let askedCard = SpotlightRequest(approval: asked, contextDirectory: "/elsewhere", home: "/Users/me")
    #expect(askedCard.ask == "Fetch the remote")
    #expect(askedCard.command == nil)
    // The request's own project outranks the session's directory.
    #expect(askedCard.directory?.display == "~/x")

    // D9: a missing command is said plainly, naming the agent that left it out.
    #expect(SpotlightRequest.missingCommand(from: .codex) == "Codex didn't say which command.")
    #expect(SpotlightRequest.missingCommand(from: .claude) == "Claude didn't say which command.")

    let bare = AgentApproval(session: claude, turn: "t1", call: "toolu_3", arrivedAt: 0)
    let bareCard = SpotlightRequest(approval: bare, contextDirectory: nil, home: nil)
    #expect(bareCard.ask == nil && bareCard.action == nil && bareCard.command == nil && bareCard.fullRequest == nil)
}

private func approvalRow(_ session: AgentSessionIdentity, readAt: Double) -> AgentAttentionItem? {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: session, turn: "t1", call: "c1", arrivedAt: 100)), now: 100)
    return queue.items(at: readAt).first
}

@Test func aLiveCardOffersApproveDenyAndOpenWithItsSecondsLeft() throws {
    let row = try #require(approvalRow(claude, readAt: 112))
    let stage = try #require(ApprovalCardStage(row, now: 112.2))
    #expect(stage == .live(try #require(ApprovalCountdown(arrivedAt: 100, expiresAt: 130, now: 112.2))))
    #expect(stage.countdown?.label == "18s left")
    #expect(stage.offersDecision && stage.showsDecisionControls)
    #expect(stage.openTitle(for: .claude) == "Open" && stage.openTitle(for: .codex) == "Open")
}

@Test func aCardPastItsDeadlineBeforeTheHandBackIsRecordedDisablesApproveAndDeny() throws {
    // The row was read live at 129.5; the card's own clock has since reached the deadline.
    let row = try #require(approvalRow(codexCLI, readAt: 129.5))
    #expect(row.kind == .actionableApproval)
    let stage = try #require(ApprovalCardStage(row, now: 130))
    #expect(stage == .expired)
    // No countdown, never "0s left", and Approve and Deny stay visible but cannot be pressed.
    #expect(stage.countdown == nil)
    #expect(!stage.offersDecision && stage.showsDecisionControls)
}

@Test func aHandedBackCardOffersOnlyOpenInItsAgent() throws {
    let codexRow = try #require(approvalRow(codexCLI, readAt: 131))
    #expect(codexRow.kind == .handedBackApproval)
    let stage = try #require(ApprovalCardStage(codexRow, now: 131))
    #expect(stage == .handedBack)
    #expect(!stage.offersDecision && !stage.showsDecisionControls && stage.countdown == nil)
    #expect(stage.openTitle(for: .codex) == "Open in Codex")
    #expect(stage.openTitle(for: .claude) == "Open in Claude")
    // A hand-back stays a hand-back even if the card's clock reads earlier than the deadline.
    #expect(ApprovalCardStage(codexRow, now: 100) == .handedBack)
}

@Test func onlyApprovalRowsHaveACardStage() {
    var queue = AgentAttentionQueue()
    queue.apply(.outcome(AgentOutcome(session: codexCLI, turn: "t2", status: .finished, arrivedAt: 100)))
    #expect(queue.items(at: 100).first.flatMap { ApprovalCardStage($0, now: 100) } == nil)
}

@Test func aCardNamesItsSourceInOneShortWord() {
    #expect(ApprovalCardReading.source(of: codexCLI) == "CLI")
    // A desktop request reaches the queue (its decision stays native), so its card names it too.
    #expect(ApprovalCardReading.source(of: codexDesktop) == "Desktop")
    #expect(ApprovalCardReading.source(of: claude) == "Claude")
    // The drawn card reads its source from its reading.
    #expect(approvalRow(claude, readAt: 110).flatMap { ApprovalCardReading($0, decidable: true, now: 110) }?.source == "Claude")
}

@Test func theApprovePillShowsOnlyWhileTheRequestCanBeDecidedHere() throws {
    let live = try #require(approvalRow(claude, readAt: 110))
    #expect(ApprovalCardKindWord(live, decidable: true) == .approve)
    #expect(ApprovalCardKindWord(live, decidable: true)?.word == "Approve")
    // A desktop request, or a Claude request with no live helper, is decided in the agent: no pill.
    #expect(ApprovalCardKindWord(live, decidable: false) == nil)
    // Handed back reads the queue's own word whatever the source could do.
    let handedBack = try #require(approvalRow(codexCLI, readAt: 131))
    #expect(ApprovalCardKindWord(handedBack, decidable: true) == .exception(.handedBack))
    #expect(ApprovalCardKindWord(handedBack, decidable: false)?.word == "Handed back")
    // Other rows have no card kind word.
    var queue = AgentAttentionQueue()
    queue.apply(.outcome(AgentOutcome(session: codexCLI, turn: "t2", status: .finished, arrivedAt: 100)))
    #expect(queue.items(at: 100).first.flatMap { ApprovalCardKindWord($0, decidable: true) } == nil)
}

@Test func pastTheDeadlineADecidableCardKeepsApproveAndDenyDisabledAndItsPillUntilTheHandBack() throws {
    // Read live at 129.5; the card's clock reaches the deadline before the hand-back is recorded.
    let row = try #require(approvalRow(codexCLI, readAt: 129.5))
    let live = try #require(ApprovalCardReading(row, decidable: true, now: 129.5))
    #expect(live.showsDecision && live.decisionEnabled && live.countdown?.seconds == 1)
    #expect(live.kindWord == .approve)

    for now in [130.0, 131, 200] {
        let expired = try #require(ApprovalCardReading(row, decidable: true, now: now))
        // Still drawn, never pressable, no countdown, and the pill stays until the hand-back.
        #expect(expired.showsDecision && !expired.decisionEnabled)
        #expect(expired.countdown == nil)
        #expect(expired.kindWord == .approve)
        #expect(expired.openTitle == "Open")
    }

    // Once the hand-back is recorded: only Open, named for the agent.
    let handedBack = try #require(approvalRow(codexCLI, readAt: 130))
    let after = try #require(ApprovalCardReading(handedBack, decidable: true, now: 130))
    #expect(!after.showsDecision && !after.decisionEnabled)
    #expect(after.kindWord == .exception(.handedBack) && after.openTitle == "Open in Codex")

    // A source that cannot decide here never draws Approve or Deny, live or not, and has no pill.
    let native = try #require(ApprovalCardReading(row, decidable: false, now: 120))
    #expect(!native.showsDecision && !native.decisionEnabled && native.kindWord == nil)
    #expect(native.countdown?.seconds == 10)
}
