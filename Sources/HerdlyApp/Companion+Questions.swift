import AppKit
import HerdlyCore

extension Companion {
    func currentClaudeQuestionRoots() -> Set<ClaudeQuestionRootKey> {
        Set(claude.roots.compactMap { root in
            guard root.status == .connected, !root.eventsPath.isEmpty,
                  let installationID = root.plan?.installationID, !installationID.isEmpty else { return nil }
            return ClaudeQuestionRootKey(sourceScope: root.url.standardizedFileURL.path,
                                         events: URL(fileURLWithPath: root.eventsPath, isDirectory: true),
                                         installationID: installationID)
        })
    }

    func observedClaudeQuestionIDs(_ scans: [ClaudeObservationScan]) -> Set<String> {
        Set(scans.flatMap { scan in
            scan.observations.compactMap { observation in
                guard case let .question(question) = observation else { return nil }
                return question.helperRequestID
            }
        })
    }

    /// A live Claude question's deadline with its hover hold, bounded as the helper bounds it.
    func claudeQuestionDeadline(_ request: ClaudeQuestionRequest) -> Double {
        claudeQuestions.deadline(for: request)
    }

    /// ADR 0020, amended 2026-10-30 (#374): while the pointer is on the notch, each live Claude
    /// question Herdly can answer keeps the time it had left, never past two minutes from publish.
    /// The hold is written for the helper a second ahead of the deadline the notch shows, so the
    /// helper never hands back while the notch still offers the answer. Holding answers nothing.
    func applyClaudeQuestionHolds(now: Double, hovering: Bool) {
        let live = claudeQuestions.live.values.filter {
            claudeQuestions.canAnswer($0.request.requestID) && claudeQuestionDeadline($0.request) > now
        }
        // The rule starts from the held deadline, so a hold kept across a missed scan (#385) resumes
        // with the time it has left instead of falling back to the 30-second window.
        questionHover.update(hovering: hovering,
                             live: live.map { .init(key: $0.request.requestID,
                                                    expiresAt: claudeQuestionDeadline($0.request)) },
                             now: now)
        for question in live {
            let requestID = question.request.requestID
            guard let deadline = questionHover.deadlines[requestID] else { continue }
            claudeQuestions.hold(question.request, until: deadline)
            writeHold(requestID, deadline: claudeQuestionDeadline(question.request),
                      to: ClaudeQuestionStore.holdURL(in: question.events, id: requestID),
                      written: &writtenQuestionHolds)
        }
        let liveIDs = Set(live.map(\.request.requestID))
        writtenQuestionHolds = writtenQuestionHolds.filter { liveIDs.contains($0.key) }
    }

    /// "Ns left" for a Claude question Herdly can answer now, from its held deadline; nil for a
    /// Codex question or one Herdly cannot answer. Display only: it never moves the deadline.
    func claudeQuestionCountdown(_ question: AgentQuestion, now: Double) -> ApprovalCountdown? {
        guard previewMode == nil, let live = liveClaudeQuestion(for: question) else { return nil }
        return ApprovalCountdown(arrivedAt: live.request.publishedAt, expiresAt: claudeQuestionDeadline(live.request),
                                 now: now)
    }

    func publishClaudeQuestionReceipts(_ works: [ClaudeQuestionReceiptWork]) {
        guard !works.isEmpty else { return }
        Task { @MainActor [weak self] in
            let results = await Task.detached(priority: .utility) {
                works.map { claudeQuestionIssueReceipt($0, now: Date().timeIntervalSince1970) }
            }.value
            self?.reconcileClaudeQuestionReceipts(results)
        }
    }

    private func reconcileClaudeQuestionReceipts(_ results: [ClaudeQuestionReceiptResult]) {
        let now = Date().timeIntervalSince1970
        let roots = currentClaudeQuestionRoots()
        for result in results {
            claudeQuestions.reconcile(result, currentGeneration: claudeQuestionScanGeneration, roots: roots, now: now)
        }
    }

    func codexQuestion(for question: AgentQuestion) -> AttentionQuestion? {
        guard question.identity.session.source == .codex,
              let session = codexSession(question.identity.session),
              let turn = UUID(uuidString: question.turn) else { return nil }
        return queue.items.compactMap(\.question).first {
            $0.session == session && $0.turn == turn && $0.callID == question.identity.call
        }
    }

    func canAnswerAgentQuestion(_ question: AgentQuestion) -> Bool {
        if previewMode == "spotlight-claude-multiselect" || previewMode == "spotlight-claude-steps",
           question.helperRequestID == "preview-helper" { return true }
        if question.identity.session.source == .claude {
            // One to four readable questions, answered as one set (#382).
            return liveClaudeQuestion(for: question) != nil && ClaudeQuestionAnswerPolicy.answerable(question.prompts)
        }
        guard let current = codexQuestion(for: question) else { return false }
        return showsOptionControls(for: current)
    }

    private func liveClaudeQuestion(for question: AgentQuestion) -> LiveClaudeQuestion? {
        let now = Date().timeIntervalSince1970
        guard question.identity.session.source == .claude,
              let requestID = question.helperRequestID,
              claudeQuestions.canAnswer(requestID),
              let live = claudeQuestions.live[requestID],
              live.sourceScope == question.identity.session.sourceScope,
              live.request.sourceScope == live.sourceScope,
              live.request.eventDirectory == live.events.standardizedFileURL.path,
              live.request.sessionID == question.identity.session.session,
              live.request.promptID == question.identity.turn,
              live.request.toolUseID == question.identity.call,
              claudeQuestionDeadline(live.request) > now,
              live.request.prompts == question.prompts,
              let liveness = ClaudeQuestionStore.liveness(for: requestID, in: live.events),
              claudeQuestionLivenessIsCurrent(liveness, request: live.request, now: now,
                                              deadline: claudeQuestionDeadline(live.request)) else { return nil }
        return live
    }

    /// A live Claude question's countdown for the keyboard card (#428): when it was published and its
    /// held deadline. Nil for a Codex question or one Herdly cannot answer. Reads; moves nothing.
    func claudeQuestionWindow(_ question: AgentQuestion) -> SpotlightKeyboardCard.Window? {
        guard previewMode == nil, let live = liveClaudeQuestion(for: question) else { return nil }
        return SpotlightKeyboardCard.Window(askedAt: live.request.publishedAt, deadline: claudeQuestionDeadline(live.request))
    }

    /// Send on a Claude card: the call's whole answer set, one entry per question in order (#382).
    /// The helper's policy refuses a partial or mismatched set, so nothing is written for one.
    func answerClaudeQuestion(_ question: AgentQuestion, answers: [ClaudeQuestionAnswerEntry]) {
        if previewMode != nil {
            refresh()
            return
        }
        guard let live = liveClaudeQuestion(for: question) else {
            refresh()
            return
        }
        let record = ClaudeQuestionAnswer(requestID: live.request.requestID,
                                          installationID: live.request.installationID,
                                          sourceScope: live.request.sourceScope,
                                          eventDirectory: live.request.eventDirectory,
                                          sessionID: live.request.sessionID,
                                          promptID: live.request.promptID,
                                          toolUseID: live.request.toolUseID,
                                          answers: answers,
                                          decidedAt: Date().timeIntervalSince1970)
        guard ClaudeQuestionAnswerPolicy.accepts(request: live.request, answer: record) else {
            refresh()
            return
        }
        let now = Date().timeIntervalSince1970
        guard let liveness = ClaudeQuestionStore.liveness(for: live.request.requestID, in: live.events),
              claudeQuestionLivenessIsCurrent(liveness, request: live.request, now: now,
                                              deadline: claudeQuestionDeadline(live.request)) else {
            refresh()
            return
        }
        // Spend the memory-only capability before writing. A failed write is never retried.
        claudeQuestions.spend(live.request.requestID, now: now)
        let noteID = AgentAttentionID.question(question.id)
        guard ClaudeQuestionStore.publish(record, in: live.events) else {
            updateRowNote(RowNoteUpdate.claudeAnswer(published: false, delivered: false), for: noteID, userAction: true)
            refresh()
            return
        }
        updateRowNote(.record(.sending), for: noteID, userAction: true)
        let request = live.request
        let events = live.events
        Task { @MainActor [weak self] in
            let delivered = await Task.detached(priority: .utility) {
                claudeQuestionAwaitDeliveryAndCleanUp(request, answer: record, in: events)
            }.value
            guard let self else { return }
            // Confirmed delivery is resolution evidence for this call; otherwise the note says so.
            self.updateRowNote(RowNoteUpdate.claudeAnswer(published: true, delivered: delivered), for: noteID)
            self.refresh()
        }
    }

    /// Open on a live Claude question (#411): hands the call back to Claude with no answer, so the
    /// helper stops waiting and Claude shows its own question. The answer token is spent first, so
    /// the card can no longer answer it and a rescan never re-grants it; the exact-identity record is
    /// then written once. A failed write is never retried and never becomes an answer: the row notes
    /// "Not delivered · answer in Claude", since Claude asks only after the helper's timer. A question
    /// no longer live (answered, expired, helper gone) is left alone: an answer already written wins.
    /// Nothing is ever answered on the user's behalf.
    func handBackClaudeQuestion(_ question: AgentQuestion) {
        guard previewMode == nil, let live = liveClaudeQuestion(for: question) else { return }
        let now = Date().timeIntervalSince1970
        guard claudeQuestions.spend(live.request.requestID, now: now) else { return }
        let record = ClaudeQuestionHandBack(for: live.request, handedBackAt: now)
        let events = live.events
        let noteID = AgentAttentionID.question(question.id)
        Task { @MainActor [weak self] in
            let published = await Task.detached(priority: .utility) {
                ClaudeQuestionStore.publish(record, in: events)
            }.value
            guard let self else { return }
            self.updateRowNote(RowNoteUpdate.claudeQuestionHandBack(published: published), for: noteID)
            if !published { self.refresh() }
        }
    }

    /// Dismissal is in memory only: a question still pending in the rollout returns after a restart.
    func dismissQuestion(_ question: AttentionQuestion) {
        queue.dismiss(.question(question.id)); refresh()
    }

    /// Progress for a question the queue holds; a fresh, ready record when Herdly has relayed nothing.
    func progress(for question: AttentionQuestion) -> QuestionAnswerProgress {
        let progress = answerProgress[question.id] ?? QuestionAnswerProgress(call: question.id)
        // Drafts made for an earlier daemon request do not carry over to a new one: the card starts over.
        if case let .daemon(request) = route(for: question),
           let draftedFor = daemonDraftRequests[question.id], draftedFor != request {
            return QuestionAnswerProgress(call: question.id)
        }
        return progress
    }

    /// Which path this question's card uses right now, in ADR 0010's precedence: a call keeps the
    /// route its first answer left by; otherwise the daemon when it holds the request, then herdr
    /// keys for a session in herdr, Ghostty keys for a CLI session not in herdr, or, for the Codex
    /// app, read-only options.
    func route(for question: AttentionQuestion) -> QuestionAnswerRoute {
        QuestionRelayRouting.route(for: question, book: daemonBook, daemonConnected: daemonConnected,
                                   ledger: relayLedger, progress: answerProgress[question.id],
                                   herdr: question.source == .cli ? herdrBinding(for: herdrKey(question)) : .notInHerdr,
                                   terminalHost: question.source == .cli ? terminalHost(forQuestionSession: question.session) : nil,
                                   unreadHost: question.source == .cli ? unreadQuestionHost(for: question.session) : nil)
    }

    private func herdrKey(_ question: AttentionQuestion) -> HerdrSessionKey {
        HerdrSessionKey(agent: .codex, sessionID: question.session.uuidString)
    }

    /// Why the herdr relay is unavailable for this question, for presentation and diagnostics: the
    /// route's own reason (no usable pane, or daemon drafts), else the last pre-send failure for the
    /// call. Nil while the relay is usable or the question is not on a herdr path. The card keeps
    /// the generic wording in `HerdrQuestionRelayUnavailable.message`.
    func herdrRelayUnavailable(for question: AttentionQuestion) -> HerdrQuestionRelayUnavailable? {
        if case let .relayUnavailable(reason) = route(for: question) { return reason }
        return relayLedger.failure(for: question.id)
    }

    /// Whether the card may show the options as controls: the daemon path, or a CLI question with
    /// Ghostty controls on. A Codex app question without the daemon is read-only (#321). Preview
    /// renders the controls as well.
    func showsOptionControls(for question: AttentionQuestion) -> Bool {
        switch route(for: question) {
        case .daemon: return true
        case .daemonAnswered: return false
        case .desktopReadOnly: return false
        // A session another enabled host may hold, or one that host cannot rule out, already routes to
        // `relayUnavailable` (ADR 0013, ADR 0017).
        case .ghosttyRelay, .herdrRelay: return ghosttyEnabled || previewMode != nil
        // A pane-bound host's digits (ADR 0017), offered only where `typesQuestionDigits` is on.
        case .terminalRelay: return true
        case .relayUnavailable: return false
        }
    }

    /// A click on an option, or its digit (D16): selects it on the card and sends nothing. The
    /// queue's current copy of the question and the route's own policy judge it first. On the daemon
    /// path an earlier question's unsent draft may be changed; a key already typed never is. A Codex
    /// app question without the daemon takes no selection.
    func selectQuestionAnswer(_ question: AttentionQuestion, question index: Int, answer: ChosenAnswer) {
        let current = queue.items.compactMap(\.question).first { $0.id == question.id }
        let progress = progress(for: question)
        let route = route(for: question)
        switch route {
        case .daemon:
            guard AppServerAnswerPolicy.rejection(for: current, book: daemonBook, progress: progress,
                                                  question: index, answer: answer) == nil else { refresh(); return }
            answerProgress[question.id] = progress.selecting(question: index, answer: answer, revisesDrafts: true)
            selectionRoutes[question.id] = route
        case .ghosttyRelay, .herdrRelay, .terminalRelay:
            guard showsOptionControls(for: question), case let .option(option) = answer,
                  QuestionAnswerPolicy.rejection(for: current, ghosttyEnabled: ghosttyEnabled || route == .terminalRelay
                                                     || previewMode != nil,
                                                 progress: progress, question: index, option: option) == nil else {
                refresh(); return
            }
            answerProgress[question.id] = progress.selecting(question: index, answer: answer)
            selectionRoutes[question.id] = route
        case .daemonAnswered, .relayUnavailable, .desktopReadOnly:
            refresh(); return
        }
        refresh()
    }

    /// Send, or Next on the daemon path, for the question the card is answering: the only way an
    /// answer leaves Herdly (D16). `typed` is the daemon field's text, which takes the place of a
    /// selected option. Daemon: Next keeps the answer as a draft; Send on the last question writes
    /// the whole call once. Key routes: one digit for this question only. Each route keeps its own
    /// fresh pending-request check immediately before anything is written.
    func sendQuestionAnswer(_ question: AttentionQuestion, question index: Int, typed: String? = nil) {
        let progress = progress(for: question)
        let typedAnswer = typed.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : ChosenAnswer.text($0) }
        let route = route(for: question)
        // A selection made on another route (the daemon let go, or a new request arrived) is dropped,
        // not sent: the user selects again on the card as it is now.
        if progress.selected[index] != nil, selectionRoutes[question.id] != route {
            if answerProgress[question.id] != nil { answerProgress[question.id] = progress.clearingSelections() }
            selectionRoutes[question.id] = nil
            refresh()
            return
        }
        switch route {
        case let .daemon(request):
            guard let answer = typedAnswer ?? progress.selected[index] else { refresh(); return }
            answerThroughDaemon(question, question: index, answer: answer, expectedRequest: request)
        case .ghosttyRelay, .herdrRelay, .terminalRelay:
            guard typedAnswer == nil, case let .option(option)? = progress.selected[index] else { refresh(); return }
            sendQuestionKey(question, question: index, option: option)
        case .daemonAnswered, .relayUnavailable, .desktopReadOnly:
            refresh()
        }
    }

    /// One key for one Send on a key route: herdr, a terminal host's pane, or Ghostty.
    private func sendQuestionKey(_ question: AttentionQuestion, question index: Int, option: Int) {
        switch route(for: question) {
        case .herdrRelay:
            answerThroughHerdr(question, question: index, option: option)
            return
        case .terminalRelay:
            answerThroughTerminalKeys(question, question: index, option: option)
            return
        case .ghosttyRelay:
            break
        case .daemon, .daemonAnswered, .relayUnavailable, .desktopReadOnly:
            refresh()
            return
        }
        guard !answering else { return }
        // Re-read the queue's current copy: a question answered since the row rendered must not be relayed.
        let current = queue.items.compactMap(\.question).first { $0.id == question.id }
        let progress = progress(for: question)
        if QuestionAnswerPolicy.rejection(for: current, ghosttyEnabled: ghosttyEnabled, progress: progress,
                                          question: index, option: option) != nil {
            refresh(); return
        }
        guard let current, previewMode == nil else { return }
        // Spend the key before sending; it is released only when Ghostty certainly sent nothing.
        guard relayLedger.spend(current.id, question: index, route: .ghostty) else {
            refresh(); return
        }
        answering = true
        answerProgress[question.id] = progress.startingSend(question: index, option: option)
        let key = QuestionAnswerPolicy.key(forOption: option)
        let live = liveCLI
        let rolloutRoot = Companion.rolloutRoot
        let switches = hostSwitches
        // Read on the main actor: a host that is not running holds nothing and is not asked.
        let running = Set(TerminalKeyRelayCheck.hostsToRead(switches: switches).filter(TerminalApps.isRunning))
        noteCodexKeySending(current, index: index)
        refresh()
        Task { @MainActor in
            let result = await Task.detached { () -> (sent: Bool, message: String) in
                // The rollout as of this instant: an answer Codex already recorded, or an ended turn,
                // means the pane is gone and the key would land in the composer instead.
                let evidence = ReminderReader.currentEvidence(for: current.session, in: rolloutRoot)
                guard QuestionAnswerGuard.stillPending(current, in: evidence) else {
                    return (false, "Codex already has an answer or the turn ended; nothing was sent.")
                }
                // ADR 0013 "Freshness": Ghostty binds by title alone, so every other enabled host is read
                // fresh last, closest to the key; an unreadable one, or one whose tab carries the title,
                // sends no key, so a Ghostty decoy never gets it (ADR 0017). A title decoy there, whose fresh
                // `ps` shows no `codex`, holds nothing (#268); a titled tab whose `ps` fails still vetoes.
                let hosts = TerminalKeyRelayCheck.hostsToRead(switches: switches)
                if !hosts.isEmpty {
                    let title = GhosttyMatch.title(current.session)
                    let fresh = Companion.freshInventories(hosts, running: running)
                    let processes = TerminalTTYReads.processes(
                        on: TerminalTabReadAssembly<Void>.ttysToRead(fresh, codexTitles: [title], claudeTTYs: []))
                    if let veto = TerminalKeyRelayCheck.ghosttyVeto(title: title, processes: processes, switches: switches,
                                                                    fresh: fresh) {
                        return (false, veto.message)
                    }
                }
                return GhosttyNavigation.answer(session: current.session, live: live, keys: [key])
            }.value
            answering = false
            updateRowNote(RowNoteUpdate.ghosttyKeyAnswer(sent: result.sent, question: index, of: current.questionCount),
                          for: Self.codexQuestionNoteID(current))
            if !result.sent { relayLedger.release(current.id, question: index) }
            guard queue.items.contains(where: { $0.id == .question(question.id) }) else {
                // Answered or ended while the key was in flight: the card is gone and so is the progress.
                answerProgress[question.id] = nil
                refresh()
                return
            }
            if let progress = answerProgress[question.id] {
                answerProgress[question.id] = result.sent
                    ? progress.recordingSent(question: index, option: option, of: current, at: Date().timeIntervalSince1970)
                    : progress.recordingFailure(result.message)
            }
            refresh()
        }
    }

    /// One Send on a herdr-bound session (ADR 0010): one `agent.send_keys` carrying only the
    /// option's digit, to the bound pane, never Enter. The key is spent before anything is sent.
    /// Immediately before it, a fresh scan re-runs ADR 0012's whole binding rule and herdr must report
    /// the pane's agent `blocked`, then the rollout is re-read. A key that may have been written
    /// counts as sent and is never resent; nothing is sent on a timer, retry, restart or error.
    private func answerThroughHerdr(_ question: AttentionQuestion, question index: Int, option: Int) {
        guard !answering else { return }
        let current = queue.items.compactMap(\.question).first { $0.id == question.id }
        let session = herdrKey(question)
        // Later questions in a keyed call go to the pane the first key went to; the send rechecks it.
        let pane: String?
        if case let .herdr(paneID)? = relayLedger.keyRoute(for: question.id) { pane = paneID }
        else { pane = herdrBinding(for: session).target?.paneID }
        let start: HerdrQuestionRelay.Start
        switch HerdrQuestionRelay.start(current: current, progress: progress(for: question), ledger: relayLedger,
                                        ghosttyEnabled: ghosttyEnabled, pane: pane, question: index, option: option) {
        case .failure:
            refresh(); return
        case let .success(value):
            start = value
        }
        guard let current, previewMode == nil else { return }
        answering = true
        relayLedger = start.ledger
        answerProgress[question.id] = start.progress
        noteCodexKeySending(current, index: index)
        refresh()
        let rolloutRoot = Companion.rolloutRoot
        let client = HerdrClient()
        Task { @MainActor in
            let fresh = await revalidateHerdrBinding(for: session)
            let outcome = await Task.detached { () -> HerdrQuestionRelay.Outcome in
                // The rollout last, as of this instant: a manual answer Codex already recorded, or an
                // ended turn, sends nothing.
                let evidence = ReminderReader.currentEvidence(for: current.session, in: rolloutRoot)
                switch HerdrQuestionRelay.preSendCheck(question: current, evidence: evidence, binding: fresh.binding,
                                                       outcome: fresh.outcome, spentPane: start.pane) {
                case let .failure(veto): return .vetoed(veto)
                case let .success(target): return .delivered(client.sendKeysOnce(target: target.paneID, keys: [start.key]))
                }
            }.value
            answering = false
            noteCodexKeyAnswer(current, index: index, outcome: outcome)
            guard queue.items.contains(where: { $0.id == .question(question.id) }) else {
                // Answered or ended while the key was in flight: the card is gone and so is the progress.
                answerProgress[question.id] = nil
                refresh()
                return
            }
            if let progress = answerProgress[question.id] {
                let settled = HerdrQuestionRelay.settle(outcome, progress: progress, ledger: relayLedger, question: current,
                                                        index: index, option: option, now: Date().timeIntervalSince1970)
                answerProgress[question.id] = settled.progress
                relayLedger = settled.ledger
            }
            refresh()
        }
    }

    /// One Next or Send through the daemon. A non-last question's answer is only drafted; the last one
    /// sends the whole call as one JSON-RPC response, after re-reading the rollout, and marks the
    /// request answered before the write so nothing is ever sent twice. Never on a timer or error.
    func answerThroughDaemon(_ question: AttentionQuestion, question index: Int, answer: ChosenAnswer,
                             expectedRequest: AppServerQuestionRequest? = nil) {
        guard !answering else { return }
        let current = queue.items.compactMap(\.question).first { $0.id == question.id }
        if AppServerAnswerPolicy.rejection(for: current, book: daemonBook, progress: progress(for: question),
                                           question: index, answer: answer) != nil {
            refresh(); return
        }
        guard let current, current.turn == question.turn, let request = daemonBook.request(for: current),
              expectedRequest == nil || expectedRequest == request else { return }
        if previewMode != nil {
            let plan = AppServerAnswering.prepare(current: current, book: daemonBook, progress: progress(for: question),
                                                  question: index, answer: answer, stillPending: { true }, now: 0)
            if case let .drafted(next) = plan.outcome {
                previewViewedQuestion = nil
                answerProgress[question.id] = next
                daemonDraftRequests[question.id] = request
            }
            // Preview completion never writes to a real transport.
            if case let .sending(next) = plan.outcome {
                answerProgress[question.id] = next.recordingSent(question: index, answer: answer, of: current, at: Date().timeIntervalSince1970)
                daemonBook = plan.book
            }
            refresh()
            return
        }
        let isLast = index + 1 >= request.questions.count
        let editing = index < progress(for: question).questionIndex
        answering = true
        let rolloutRoot = Companion.rolloutRoot
        Task { @MainActor in
            // The rollout as of this instant, only when the answer would leave Herdly: an answer Codex
            // already recorded, or an ended turn, means the daemon request is stale.
            let pending = (isLast || editing) ? await Task.detached {
                QuestionAnswerGuard.stillPending(current, in: ReminderReader.currentEvidence(for: current.session, in: rolloutRoot))
            }.value : true
            let now = Date().timeIntervalSince1970
            let latest = queue.items.compactMap(\.question).first { $0.id == question.id }
            guard latest?.turn == current.turn, daemonBook.request(for: current) == request else {
                answering = false
                refresh()
                return
            }
            let plan = AppServerAnswering.prepare(current: latest, book: daemonBook, progress: progress(for: question),
                                                  question: index, answer: answer, stillPending: { pending }, now: now)
            daemonBook = plan.book
            switch plan.outcome {
            case .refused:
                break
            case let .drafted(next):
                answerProgress[question.id] = next
                daemonDraftRequests[question.id] = request
            case let .sending(next):
                answerProgress[question.id] = next
                let written = plan.message.map { daemonClient.send($0) } ?? false
                if let latest {
                    answerProgress[question.id] = written
                        ? next.recordingSent(question: index, answer: answer, of: latest, at: now)
                        : next.recordingFailure("Could not write to Codex's daemon; Herdly will not retry. Answer in Codex.")
                }
                updateRowNote(RowNoteUpdate.codexDaemonAnswer(sent: written), for: Self.codexQuestionNoteID(current), userAction: true)
            }
            answering = false
            refresh()
        }
    }

    /// Drops progress for questions no longer waiting and turns an unconfirmed send into its final state.
    func pruneAnswerProgress() {
        let waiting = Set(queue.items.compactMap { $0.question?.id })
        let drafts = daemonDraftRequests.filter { waiting.contains($0.key) }
        if drafts.count != daemonDraftRequests.count { daemonDraftRequests = drafts }
        let routes = selectionRoutes.filter { waiting.contains($0.key) }
        if routes.count != selectionRoutes.count { selectionRoutes = routes }
        var ledger = relayLedger
        ledger.prune(keeping: waiting)
        if ledger != relayLedger { relayLedger = ledger }
        guard !answerProgress.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let next = answerProgress.filter { waiting.contains($0.key) }.mapValues { $0.expiring(at: now) }
        if next != answerProgress { answerProgress = next }
    }
}

/// One key the panel handed to the question card on screen (#321). `serial` makes a repeated key a
/// new value, so the card sees every press; `card` is the card it was pressed on.
struct QuestionCardKeyPress: Equatable {
    /// What the key does on the card, from `SpotlightCardKeys`, the one key table (#321, #428).
    let action: SpotlightCardAction
    let card: AgentAttentionID
    let serial: Int
}

/// One key the panel handed to the approval card on screen (#439). `serial` makes a repeated key a
/// new value, so the card sees every press; `card` is the card it was pressed on.
struct ApprovalCardKeyPress: Equatable {
    /// What the key does on the card, from `ApprovalCardKeys`, the one approval key table.
    let action: ApprovalCardAction
    let card: AgentAttentionID
    let serial: Int
}

/// One key the panel handed to the walk's result card (#440). `serial` makes a repeated key a new
/// value, so the card sees every press; `card` is the card it was pressed on.
struct ResultCardKeyPress: Equatable {
    /// What the key does on the card, from `ResultCardKeys`.
    let action: ResultCardAction
    let card: AgentAttentionID
    let serial: Int
}

/// ← or → pressed on a walk card that shows a question (#440). The card answers it with its viewed
/// question (`Companion.stepWalk`), so a call of several questions steps them first.
struct WalkKeyPress: Equatable {
    let direction: ToCheckWalk.Direction
    let card: AgentAttentionID
    let serial: Int
}
