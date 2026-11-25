import AppKit
import HerdlyCore
import SwiftUI

// Settings › Agents rows (#481, Paper "Agents tab like Terminals", A1–A9). The page and its card are
// `AgentControls` in ControlsView.swift; the rules for each row are `AgentSettingsRow` in HerdlyCore.

/// The Codex row: the switch runs Configure Codex or Undo Setup at once (A3).
struct CodexAgentRow: View {
    @ObservedObject var model: Companion
    @Binding var sheet: SetupPreview?

    private var readyPlan: CodexSetupPlan? {
        guard let plan = model.setupPlan, case .ready = plan.status else { return nil }
        return plan
    }

    /// `setupStatus` is only a default until the first detection lands, so the row reads Checking until then.
    private var row: AgentSettingsRow {
        AgentSettingsRow.codex(model.setupCapabilities, status: model.setupChecked ? model.setupStatus : nil,
                               statusText: model.setupStatusText, installed: model.setupInstalled,
                               planReady: readyPlan != nil, restartAfterUpdate: model.agentUpdates.restartRequired(.codex))
    }

    var body: some View {
        let row = row
        let capabilities = model.setupCapabilities
        AgentRowView(name: "Codex", agent: .codex, row: row, message: model.setupMessage,
                     lineActions: AgentLineActions(updates: model.agentUpdates,
                                                   action: { AgentRowAction.codex($0, capabilities) },
                                                   perform: model.performAgentRowAction,
                                                   configure: { model.configureCodex() }),
                     setSwitch: { on in
                         switch AgentSwitchChange.change(to: on, row) {
                         case .configure?: model.configureCodex()
                         case .undo?: model.undoCodexSetup()
                         case nil: nil
                         }
                     }) {
            Button("Review Again", action: model.refreshSetup)
            if let plan = readyPlan, plan.requiresConfigure {
                Button("Show Setup Changes…") {
                    let hooks = String(data: plan.hooksChange, encoding: .utf8) ?? "(unreadable)"
                    sheet = SetupPreview(title: "Codex setup changes",
                                         text: "config.toml\n\(plan.configChange)\n\nhooks.json\n\(hooks)\n\nhelper command\n\(plan.helperCommand)")
                }
            }
            Button("Show Diagnostics…") {
                sheet = SetupPreview(title: "Codex diagnostics", text: diagnostics)
            }
            .disabled(!model.setupChecked)
        }
    }

    private var diagnostics: String {
        AgentDiagnostics.codex(model.setupCapabilities, installed: model.setupInstalled, statusText: model.setupStatusText)
    }
}

/// A row per Claude folder: the default one named "Claude Code", each added one "Claude Code · <path>" (A7).
struct ClaudeAgentRows: View {
    @ObservedObject var setup: ClaudeSetupModel
    @Binding var sheet: SetupPreview?
    let updates: AgentUpdates
    let perform: (AgentUpdateTarget, AgentRowAction) -> Void

    var body: some View {
        ForEach(setup.roots) { root in
            let isDefault = root.id == setup.roots.first?.id
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            folderRow(root, isDefault: isDefault)
        }
    }

    private func readyPlan(_ root: ClaudeSetupModel.Root) -> ClaudeSetupPlan? {
        guard let plan = root.plan, case .ready = plan.status else { return nil }
        return plan
    }

    private func name(_ root: ClaudeSetupModel.Root, isDefault: Bool) -> String {
        isDefault ? "Claude Code" : "Claude Code · \(root.displayPath)"
    }

    /// A folder's status is only a placeholder until the first detection lands, so it reads Checking until then.
    private func row(_ root: ClaudeSetupModel.Root) -> AgentSettingsRow {
        AgentSettingsRow.claude(root.capabilities, status: setup.checked ? root.status : nil,
                                statusText: ClaudeSetupModel.statusText(root.status), installed: root.installed,
                                setup: ClaudeFolderSetup(plan: root.plan, usageInstalled: root.usageInstalled,
                                                         usageStatus: root.usageStatus),
                                restartAfterUpdate: updates.restartRequired(.claude))
    }

    private func folderRow(_ root: ClaudeSetupModel.Root, isDefault: Bool) -> some View {
        let row = row(root)
        let name = name(root, isDefault: isDefault)
        let capabilities = root.capabilities
        // The model keeps one last-result message for every folder; it shows under the default row.
        return AgentRowView(name: name, agent: .claude, row: row, message: isDefault ? setup.message : "",
                            lineActions: AgentLineActions(updates: updates,
                                                          action: { AgentRowAction.claude($0, capabilities) },
                                                          perform: perform,
                                                          configure: { setup.configure(root) }),
                            setSwitch: { on in
                                switch AgentSwitchChange.change(to: on, row) {
                                case .configure?: setup.configure(root)
                                case .undo?: setup.undo(root)
                                case nil: nil
                                }
                            }) {
            if let plan = readyPlan(root) {
                Button("Review Again", action: setup.refresh)
                    .accessibilityLabel("Review Claude setup for \(root.displayPath)")
                Button("Show Setup Changes…") {
                    sheet = SetupPreview(title: "Claude Code setup changes for \(root.displayPath)",
                                         text: AgentDiagnostics.claudeSetupChanges(
                                             plan, settingsPath: root.settingsPath, helperPath: root.helperPath,
                                             eventsPath: root.eventsPath, statePath: root.statePath,
                                             backupsPath: root.backupsPath, usageInstalled: root.usageInstalled))
                }
                .accessibilityLabel("Show Claude setup changes for \(root.displayPath)")
            }
            Button("Show Diagnostics…") {
                sheet = SetupPreview(title: "\(name) diagnostics", text: diagnostics(root))
            }
            .disabled(!setup.checked)
            if isDefault {
                Button("Add Another Claude Folder…", action: setup.addAlternateRoot)
            } else {
                Divider()
                Button("Remove Folder", role: .destructive) { setup.removeAlternateRoot(root) }
                    .accessibilityLabel("Remove Claude folder \(root.displayPath)")
            }
        }
    }

    private func diagnostics(_ root: ClaudeSetupModel.Root) -> String {
        AgentDiagnostics.claude(root.capabilities, displayPath: root.displayPath, installed: root.installed,
                                statusText: ClaudeSetupModel.statusText(root.status), usageInstalled: root.usageInstalled,
                                usage: AgentSummary.claudeUsage(root.usage, status: root.usageStatus,
                                                                now: Date().timeIntervalSince1970),
                                activeSessions: root.activeSessionStatus.displayText)
    }
}

/// What a row's lines need for their one trailing button: each version line's update state, the
/// button a problem gets and what pressing it does, and Configure for a line that offers it.
private struct AgentLineActions {
    let updates: AgentUpdates
    let action: (AgentProblem.Kind) -> AgentRowAction
    let perform: (AgentUpdateTarget, AgentRowAction) -> Void
    let configure: () -> Void
}

/// One agent's row, metric for metric a `TerminalHostRow` with the app's icon first: icon, name, status
/// badge, switch and ⋯, then its lines indented to the name with no divider between them.
/// `setSwitch` returns the setup task it started, so the switch can show the new position until it ends.
private struct AgentRowView<Actions: View>: View {
    let name: String
    let agent: AgentSource
    let row: AgentSettingsRow
    let message: String
    let lineActions: AgentLineActions
    let setSwitch: (Bool) -> Task<Void, Never>?
    @ViewBuilder let actions: Actions
    /// The position the user chose while its Configure or Undo runs.
    @State private var pending: Bool?

    private static var iconSize: CGFloat { 22 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AgentAppIcon(agent: agent).frame(width: Self.iconSize, height: Self.iconSize)
                HStack(spacing: 10) {
                    Text(name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    AgentRowBadgeView(badge: row.badge)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.accessibilityLabel(name: name))
                HostSwitch(label: "Herdly hooks for \(name)", isOn: Binding(
                    get: { pending ?? row.hooksInstalled },
                    set: { on in
                        guard let task = setSwitch(on) else { return }
                        pending = on
                        Task { @MainActor in
                            await task.value
                            pending = nil
                        }
                    }))
                    .disabled(!row.switchEnabled || pending != nil)
                AgentActionsMenu(label: "\(name) actions") { actions }
            }
            .padding(.horizontal, SettingsStyle.rowInset)
            .frame(minHeight: 38)
            if !row.lines.isEmpty || !message.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(row.lines, id: \.self) { AgentLineView(line: $0, actions: lineActions) }
                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, SettingsStyle.rowInset + Self.iconSize + 10)
                .padding(.trailing, SettingsStyle.rowInset)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A line under an agent's row: the restart line in plain text with its command in monospace, a
/// problem with its dot and any Update / Open Codex / Configure button, or a grey note.
private struct AgentLineView: View {
    let line: AgentRowLine
    let actions: AgentLineActions

    var body: some View {
        switch line {
        case .restart(let text):
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        case .note(let text):
            CardProblemLine(text, dot: .gray)
        case let .problem(problem, configures):
            if let target = AgentUpdateTarget(problem.kind) {
                let action = actions.action(problem.kind)
                let update = actions.updates.row(target, value: problem.value, action: action)
                CardProblemLine(AgentRowLine.text(problem, value: update.text), dot: dot(update.tone)) {
                    if let button = update.button {
                        Button(button.title) { actions.perform(target, action) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(!button.enabled)
                            .accessibilityLabel(button.accessibilityLabel)
                    }
                }
            } else {
                CardProblemLine(AgentRowLine.text(problem, value: problem.value)) {
                    if configures {
                        Button("Configure", action: actions.configure).controlSize(.small)
                    }
                }
            }
        }
    }

    private func dot(_ tone: AgentUpdateRow.Tone) -> Color {
        switch tone {
        case .attention: .orange
        case .progress: .gray
        case .failure: .red
        }
    }
}

/// The badge pill in Terminals' styling (A6); a small spinner until the first detection lands.
private struct AgentRowBadgeView: View {
    let badge: AgentRowBadge?

    var body: some View {
        if let badge {
            let (foreground, fill): (Color, Color) = switch badge {
            case .ready: (SettingsStyle.readyText, SettingsStyle.readyFill)
            case .restartRequired, .needsAttention: (SettingsStyle.attentionText, SettingsStyle.attentionFill)
            case .off: (.secondary, SettingsStyle.quietFill)
            }
            StatusPill(title: badge.title, foreground: foreground, fill: fill)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// The app's own icon at 22pt with 5pt corners (A2), or the symbol tile the cards used before when the
/// app isn't installed. Hidden from VoiceOver; the row's label names the agent.
private struct AgentAppIcon: View {
    let agent: AgentSource
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                let (symbol, tile): (String, Color) = agent == .codex
                    ? ("terminal", SettingsStyle.codexTile) : ("sparkle", SettingsStyle.claudeTile)
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(tile)
            }
        }
        .clipShape(.rect(cornerRadius: 5, style: .continuous))
        .accessibilityHidden(true)
        .task { icon = await AgentAppIcons.icon(for: agent) }
    }
}
