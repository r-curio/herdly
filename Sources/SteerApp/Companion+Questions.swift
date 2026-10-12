import AppKit
import SteerCore

extension Companion {
    func claudeQuestionRootKey(sourceScope: String, events: URL, installationID: String) -> ClaudeQuestionRootKey {
        ClaudeQuestionRootKey(sourceScope: sourceScope,
                              eventsPath: events.standardizedFileURL.path,
                              installationID: installationID)
    }

    func currentClaudeQuestionRoots() -> Set<ClaudeQuestionRootKey> {
        Set(claude.roots.compactMap { root in
            guard root.status == .connected, !root.eventsPath.isEmpty,
                  let installationID = root.plan?.installationID, !installationID.isEmpty else { return nil }
            return claudeQuestionRootKey(sourceScope: root.url.standardizedFileURL.path,
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

    func pruneClaudeQuestionState(now: Double, roots: Set<ClaudeQuestionRootKey>,
                                          pendingIDs: Set<String>, observedIDs: Set<String>) {
        let retained = liveClaudeQuestions.filter { requestID, live in
            let root = claudeQuestionRootKey(sourceScope: live.sourceScope, events: live.events,
                                             installationID: live.request.installationID)
            return live.request.expiresAt > now && roots.contains(root)
                && (pendingIDs.contains(requestID) || observedIDs.contains(requestID))
        }
        let retainedIDs = Set(retained.keys)
        liveClaudeQuestions = retained
        availableClaudeQuestionTokens = availableClaudeQuestionTokens.filter { retainedIDs.contains($0) }
        spentClaudeQuestionTokens = spentClaudeQuestionTokens.filter { retainedIDs.contains($0) }
        pendingClaudeQuestionReceipts = pendingClaudeQuestionReceipts.filter { retainedIDs.contains($0) }
    }

    func publishClaudeQuestionReceipts(_ works: [ClaudeQuestionReceiptWork]) {
        guard !works.isEmpty else { return }
        Task { @MainActor [weak self] in
            let results = await Task.detached(priority: .utility) {
                works.map { work -> ClaudeQuestionReceiptResult in
                    let now = Date().timeIntervalSince1970
                    guard work.request.expiresAt > now else {
                        return ClaudeQuestionReceiptResult(request: work.request, requestID: work.request.requestID,
                                                          root: work.root,
                                                          scanGeneration: work.scanGeneration, written: false)
                    }
                    let receipt = ClaudeQuestionReceipt(requestID: work.request.requestID,
                                                        installationID: work.request.installationID,
                                                        sourceScope: work.request.sourceScope,
                                                        eventDirectory: work.request.eventDirectory,
                                                        receivedAt: now, expiresAt: work.request.expiresAt)
                    let written = ClaudeQuestionStore.publish(
                        receipt, in: URL(fileURLWithPath: work.eventsPath, isDirectory: true))
                    return ClaudeQuestionReceiptResult(request: work.request, requestID: work.request.requestID,
                                                      root: work.root,
                                                      scanGeneration: work.scanGeneration, written: written)
                }
            }.value
            self?.reconcileClaudeQuestionReceipts(results)
        }
    }

    private func reconcileClaudeQuestionReceipts(_ results: [ClaudeQuestionReceiptResult]) {
        let now = Date().timeIntervalSince1970
        let roots = currentClaudeQuestionRoots()
        for result in results {
            let live = liveClaudeQuestions[result.requestID]
            let rootIsCurrent = roots.contains(result.root)
                && live.map {
                    claudeQuestionRootKey(sourceScope: $0.sourceScope, events: $0.events,
                                          installationID: $0.request.installationID) == result.root
                        && $0.request.sourceScope == $0.sourceScope
                        && $0.request.eventDirectory == $0.events.standardizedFileURL.path
                } == true
            let disposition = claudeQuestionReceiptDisposition(
                result, currentGeneration: claudeQuestionScanGeneration, liveRequest: live?.request,
                rootIsCurrent: rootIsCurrent, now: now)
            pendingClaudeQuestionReceipts.remove(result.requestID)
            switch disposition {
            case .accept, .staleAccept:
                availableClaudeQuestionTokens.insert(result.requestID)
            case .discard:
                continue
            }
        }
    }

    func chooseAgentOption(_ question: AgentQuestion, index: Int, option: Int) {
        if question.identity.session.source == .claude {
            guard index == 0, let prompt = question.prompts.first, option >= 0, option < prompt.options.count else {
                navigationMessage = "Claude question shape is unavailable; answer it in Claude."
                refresh()
                return
            }
            answerClaudeQuestion(question, kind: .option, answer: prompt.options[option])
            return
        }
        guard question.identity.session.source == .codex,
              let session = codexSession(question.identity.session),
              let turn = UUID(uuidString: question.turn),
              let current = queue.items.compactMap(\.question).first(where: { $0.session == session && $0.turn == turn && $0.callID == question.identity.call }) else {
            navigationMessage = "Claude questions are answered in Claude."
            refresh()
            return
        }
        chooseOption(current, question: index, option: option)
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
        if question.identity.session.source == .claude {
            return liveClaudeQuestion(for: question) != nil && question.prompts.count == 1
                && question.prompts.first?.question != nil
        }
        guard let current = codexQuestion(for: question) else { return false }
        return showsOptionControls(for: current)
    }

    private func liveClaudeQuestion(for question: AgentQuestion) -> LiveClaudeQuestion? {
        let now = Date().timeIntervalSince1970
        guard question.identity.session.source == .claude,
              let requestID = question.helperRequestID,
              availableClaudeQuestionTokens.contains(requestID),
              let live = liveClaudeQuestions[requestID],
              live.sourceScope == question.identity.session.sourceScope,
              live.request.sourceScope == live.sourceScope,
              live.request.eventDirectory == live.events.standardizedFileURL.path,
              live.request.sessionID == question.identity.session.session,
              live.request.promptID == question.identity.turn,
              live.request.toolUseID == question.identity.call,
              live.request.expiresAt > now,
              live.request.prompts == question.prompts,
              let liveness = ClaudeQuestionStore.liveness(for: requestID, in: live.events),
              claudeQuestionLivenessIsCurrent(liveness, request: live.request, now: now) else { return nil }
        return live
    }

    func answerClaudeQuestion(_ question: AgentQuestion, kind: ClaudeQuestionAnswerKind, answer: String) {
        guard let live = liveClaudeQuestion(for: question) else {
            navigationMessage = "Claude's question answer control is unavailable; check Claude's native question."
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
                                          kind: kind, answer: answer,
                                          decidedAt: Date().timeIntervalSince1970)
        guard ClaudeQuestionAnswerPolicy.accepts(request: live.request, answer: record) else {
            navigationMessage = "That answer is not valid for Claude's current question."
            refresh()
            return
        }
        let now = Date().timeIntervalSince1970
        guard let liveness = ClaudeQuestionStore.liveness(for: live.request.requestID, in: live.events),
              claudeQuestionLivenessIsCurrent(liveness, request: live.request, now: now) else {
            navigationMessage = "Claude answer delivery is unavailable; check Claude's question."
            refresh()
            return
        }
        // Spend the memory-only capability before writing. A failed write is never retried.
        availableClaudeQuestionTokens.remove(live.request.requestID)
        spentClaudeQuestionTokens.insert(live.request.requestID)
        guard ClaudeQuestionStore.publish(record, in: live.events) else {
            navigationMessage = "Claude answer delivery could not be confirmed; check Claude's question."
            refresh()
            return
        }
        let request = live.request
        let events = live.events
        Task { @MainActor [weak self] in
            let delivered = await Task.detached(priority: .utility) {
                claudeQuestionAwaitDeliveryAndCleanUp(request, answer: record, in: events)
            }.value
            guard let self else { return }
            self.navigationMessage = delivered
                ? "Answer sent to Claude."
                : "Claude answer delivery could not be confirmed; check Claude's question."
            self.refresh()
        }
    }

    /// Dismissal is in memory only: a question still pending in the rollout returns after a restart.
    func dismissQuestion(_ question: AttentionQuestion) {
        queue.dismiss(.question(question.id)); refresh()
    }

    /// Progress for a question the queue holds; a fresh, ready record when Steer has relayed nothing.
    func progress(for question: AttentionQuestion) -> QuestionAnswerProgress {
        let progress = answerProgress[question.id] ?? QuestionAnswerProgress(call: question.id)
        // A desktop pick made before the daemon delivered the request opened Codex and nothing more;
        // the daemon card starts from its first question.
        if case .daemon = route(for: question) { return progress.reopeningForDaemon() }
        return progress
    }

    /// Which path this question's card uses right now, in ADR 0010's precedence: a call keeps the
    /// route its first answer left by; otherwise the daemon when it holds the request, then herdr
    /// keys for a session in herdr, Ghostty keys for a CLI session not in herdr, or the desktop pick.
    func route(for question: AttentionQuestion) -> QuestionAnswerRoute {
        QuestionRelayRouting.route(for: question, book: daemonBook, daemonConnected: daemonConnected,
                                   ledger: relayLedger, progress: answerProgress[question.id],
                                   herdr: question.source == .cli ? herdrBinding(for: herdrKey(question)) : .notInHerdr)
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

    /// Whether the card may show the options as controls: the daemon path, a CLI question with
    /// Ghostty controls on, or a desktop question (whose pick only opens Codex). Preview renders the
    /// controls as well.
    func showsOptionControls(for question: AttentionQuestion) -> Bool {
        switch route(for: question) {
        case .daemon: return true
        case .daemonAnswered: return false
        case .desktopPick: return true
        // ADR 0017: never offer a key for a session iTerm2 may hold (`iTerm2InputLine` says why).
        case .ghosttyRelay, .herdrRelay: return (ghosttyEnabled || previewMode != nil) && iTerm2InputBlock(for: question.session) == nil
        case .relayUnavailable: return false
        }
    }

    /// One click on an option. Daemon: the exact answer by call id. Desktop: remember the pick and
    /// open the thread. CLI: relay the digit through Ghostty after re-checking the queue, the policy,
    /// and the rollout as it is right now.
    func chooseOption(_ question: AttentionQuestion, question index: Int, option: Int) {
        switch route(for: question) {
        case .daemon:
            answerThroughDaemon(question, question: index, answer: .option(option))
            return
        case .daemonAnswered:
            navigationMessage = AppServerAnswerPolicy.message(for: .alreadyAnswered); refresh()
            return
        case .herdrRelay:
            answerThroughHerdr(question, question: index, option: option)
            return
        case let .relayUnavailable(reason):
            navigationMessage = reason.message; refresh()
            return
        case .desktopPick, .ghosttyRelay:
            break
        }
        if question.source == .desktop {
            guard case .options = QuestionAnswerProgress.offer(question, at: index) else { return }
            answerProgress[question.id] = progress(for: question).pickingInCodex(question: index, option: option)
            openAttentionSession(source: .desktop, session: question.session)
            return
        }
        guard !answering else { return }
        // Re-read the queue's current copy: a question answered since the row rendered must not be relayed.
        let current = queue.items.compactMap(\.question).first { $0.id == question.id }
        let progress = progress(for: question)
        if let rejection = QuestionAnswerPolicy.rejection(for: current, ghosttyEnabled: ghosttyEnabled, progress: progress,
                                                          question: index, option: option) {
            navigationMessage = QuestionAnswerPolicy.message(for: rejection); refresh(); return
        }
        guard let current, previewMode == nil else { return }
        // Spend the key before sending; it is released only when Ghostty certainly sent nothing.
        guard relayLedger.spend(current.id, question: index, route: .ghostty) else {
            navigationMessage = QuestionAnswerPolicy.message(for: .notReady); refresh(); return
        }
        answering = true
        answerProgress[question.id] = progress.startingSend(question: index, option: option)
        let key = QuestionAnswerPolicy.key(forOption: option)
        let live = liveCLI
        let rolloutRoot = Companion.rolloutRoot
        let title = GhosttyMatch.title(current.session)
        let iTerm2On = hostSwitches.mayContact(.iTerm2)
        let iTerm2Running = iTerm2On && TerminalApps.isRunning(.iTerm2)
        navigationMessage = "Sending \(key)…"
        refresh()
        Task { @MainActor in
            let result = await Task.detached { () -> (sent: Bool, message: String) in
                // The rollout as of this instant: an answer Codex already recorded, or an ended turn,
                // means the pane is gone and the key would land in the composer instead.
                let evidence = ReminderReader.currentEvidence(for: current.session, in: rolloutRoot)
                guard QuestionAnswerGuard.stillPending(current, in: evidence) else {
                    return (false, "Codex already has an answer or the turn ended; nothing was sent.")
                }
                // ADR 0013 "Freshness": the title must be unique across every enabled inventory, so a
                // fresh iTerm2 read comes last; a Ghostty decoy never gets the key (ADR 0017).
                if let block = Companion.freshITerm2InputBlock(title: title, on: iTerm2On, running: iTerm2Running) {
                    return (false, "\(block.line) Nothing was sent.")
                }
                return GhosttyNavigation.answer(session: current.session, live: live, keys: [key])
            }.value
            answering = false
            navigationMessage = result.message
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

    /// One click on a herdr-bound session (ADR 0010): one `agent.send_keys` carrying only the
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
        case let .failure(.policy(rejection)):
            navigationMessage = QuestionAnswerPolicy.message(for: rejection); refresh(); return
        case .failure(.noPane):
            navigationMessage = HerdrQuestionRelayUnavailable.leftHerdr.message; refresh(); return
        case .failure(.alreadySent):
            navigationMessage = QuestionAnswerPolicy.message(for: .notReady); refresh(); return
        case let .success(value):
            start = value
        }
        guard let current, previewMode == nil else { return }
        answering = true
        relayLedger = start.ledger
        answerProgress[question.id] = start.progress
        navigationMessage = "Sending \(start.key)…"
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
            switch outcome {
            case let .delivered(delivery) where delivery.countsAsSent:
                navigationMessage = "Sent \(start.key) as a key."
            case let .vetoed(reason):
                navigationMessage = reason.message
            case .delivered:
                navigationMessage = HerdrQuestionRelayUnavailable.herdrRefused(.notRunning).message
            }
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

    /// A typed answer; only the daemon path takes one.
    func answerText(_ question: AttentionQuestion, question index: Int, text: String) {
        guard case .daemon = route(for: question) else {
            navigationMessage = "Typed answers need Codex's daemon; answer this one in Codex."; refresh()
            return
        }
        answerThroughDaemon(question, question: index, answer: .text(text))
    }

    /// One answer through the daemon. A non-last question's answer is only drafted; the last one
    /// sends the whole call as one JSON-RPC response, after re-reading the rollout, and marks the
    /// request answered before the write so nothing is ever sent twice. Never on a timer or error.
    private func answerThroughDaemon(_ question: AttentionQuestion, question index: Int, answer: ChosenAnswer) {
        guard !answering else { return }
        let current = queue.items.compactMap(\.question).first { $0.id == question.id }
        if let rejection = AppServerAnswerPolicy.rejection(for: current, book: daemonBook, progress: progress(for: question),
                                                           question: index, answer: answer) {
            navigationMessage = AppServerAnswerPolicy.message(for: rejection); refresh(); return
        }
        guard let current, previewMode == nil, let request = daemonBook.request(for: current) else { return }
        let isLast = index + 1 >= request.questions.count
        answering = true
        navigationMessage = ""
        let rolloutRoot = Companion.rolloutRoot
        Task { @MainActor in
            // The rollout as of this instant, only when the answer would leave Steer: an answer Codex
            // already recorded, or an ended turn, means the daemon request is stale.
            let pending = isLast ? await Task.detached {
                QuestionAnswerGuard.stillPending(current, in: ReminderReader.currentEvidence(for: current.session, in: rolloutRoot))
            }.value : true
            let now = Date().timeIntervalSince1970
            let latest = queue.items.compactMap(\.question).first { $0.id == question.id }
            let plan = AppServerAnswering.prepare(current: latest, book: daemonBook, progress: progress(for: question),
                                                  question: index, answer: answer, stillPending: { pending }, now: now)
            daemonBook = plan.book
            switch plan.outcome {
            case let .refused(rejection):
                navigationMessage = AppServerAnswerPolicy.message(for: rejection)
            case let .drafted(next):
                answerProgress[question.id] = next
            case let .sending(next):
                answerProgress[question.id] = next
                let written = plan.message.map { daemonClient.send($0) } ?? false
                if let latest {
                    answerProgress[question.id] = written
                        ? next.recordingSent(question: index, answer: answer, of: latest, at: now)
                        : next.recordingFailure("Could not write to Codex's daemon; Steer will not retry. Answer in Codex.")
                }
                navigationMessage = written ? "Answer sent to Codex's daemon." : "Could not write to Codex's daemon."
            }
            answering = false
            refresh()
        }
    }

    /// Drops progress for questions no longer waiting and turns an unconfirmed send into its final state.
    func pruneAnswerProgress() {
        let waiting = Set(queue.items.compactMap { $0.question?.id })
        var ledger = relayLedger
        ledger.prune(keeping: waiting)
        if ledger != relayLedger { relayLedger = ledger }
        guard !answerProgress.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let next = answerProgress.filter { waiting.contains($0.key) }.mapValues { $0.expiring(at: now) }
        if next != answerProgress { answerProgress = next }
    }
}
