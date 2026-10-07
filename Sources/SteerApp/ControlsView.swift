import AppKit
import SwiftUI
import SteerCore

private enum ControlSection: String, CaseIterable, Identifiable {
    case general
    case agents
    case terminals
    case notifications
    case advanced
    case about

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .agents: "sparkles"
        case .terminals: "terminal.fill"
        case .notifications: "bell.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        case .about: "info.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .general: .gray
        case .agents: .indigo
        case .terminals: .mint
        case .notifications: .orange
        case .advanced: .blue
        case .about: .cyan
        }
    }
}

struct Controls: View {
    @ObservedObject var model: Companion
    @State private var selection: ControlSection

    init(model: Companion) {
        self.model = model
        // This is an intentional one-time navigation seed: restore the user's last section, then
        // let setup lead on a fresh install until an agent is connected.
        let saved = UserDefaults.standard.string(forKey: "controlsSection").flatMap(ControlSection.init(rawValue:))
        _selection = State(initialValue: saved ?? (model.canUndoSetup ? .general : .agents))
    }

    var body: some View {
        NavigationSplitView {
            ControlsSidebar(selection: $selection, quit: model.quit)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 230)
        } detail: {
            ControlsDetail(section: selection, model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 540)
        .onChange(of: selection) { _, section in
            UserDefaults.standard.set(section.rawValue, forKey: "controlsSection")
        }
    }
}

private struct ControlsSidebar: View {
    @Binding var selection: ControlSection
    let quit: () -> Void

    private let primarySections: [ControlSection] = [.general, .agents, .terminals, .notifications, .advanced]

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(primarySections) { section in
                    SidebarLabel(section: section).tag(section)
                }

                Section {
                    SidebarLabel(section: .about).tag(ControlSection.about)
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button(role: .destructive, action: quit) {
                Label("Quit Steer", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .accessibilityHint("Stops Steer and closes its menu-bar companion.")
        }
    }
}

private struct SidebarLabel: View {
    let section: ControlSection

    var body: some View {
        Label {
            Text(section.title).font(.body.weight(.medium))
        } icon: {
            Image(systemName: section.symbol)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(section.color, in: .rect(cornerRadius: 7))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
    }
}

private struct ControlsDetail: View {
    let section: ControlSection
    @ObservedObject var model: Companion

    var body: some View {
        switch section {
        case .general: GeneralControls(model: model)
        case .agents: AgentControls(model: model)
        case .terminals: TerminalControls(model: model)
        case .notifications: NotificationControls(model: model)
        case .advanced: AdvancedControls(model: model)
        case .about: AboutControls()
        }
    }
}

private struct ControlsPage<Content: View>: View {
    let section: ControlSection
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Image(systemName: section.symbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(section.color, in: .rect(cornerRadius: 10))
                        .accessibilityHidden(true)
                    Text(section.title).font(.title.bold())
                }
                content
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(30)
        }
        .background(.background)
        .navigationTitle(section.title)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45)) }
            .compositingGroup()
            .clipShape(.rect(cornerRadius: 12))
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 20)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct StatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(title)")
    }
}

private struct GeneralControls: View {
    @ObservedObject var model: Companion

    private var isConnected: Bool { model.canUndoSetup }

    var body: some View {
        ControlsPage(section: .general) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isConnected ? "Steer is monitoring agent sessions" : "Steer needs an agent connection")
                    .font(.title3.weight(.semibold))
                Text(isConnected ? "\(model.workingCount) working · \(model.toCheckCount) to check" : model.setupStatusText)
                    .foregroundStyle(.secondary)
                StatusBadge(title: isConnected ? "Connected" : "Setup required", color: isConnected ? .green : .orange)
            }

            Text("Connections").font(.headline).foregroundStyle(.secondary)
            SettingsCard {
                SettingsRow(title: "Agents", detail: isConnected ? "Codex is connected." : "Connect an agent to start monitoring work.") {
                    StatusBadge(title: isConnected ? "Ready" : "Setup required", color: isConnected ? .green : .orange)
                }
                Divider()
                SettingsRow(title: "Terminals", detail: model.ghosttyEnabled ? "Ghostty controls are enabled." : "No terminal controls are enabled.") {
                    StatusBadge(title: model.ghosttyEnabled ? "Enabled" : "Off", color: model.ghosttyEnabled ? .green : .secondary)
                }
                Divider()
                SettingsRow(title: "Notifications", detail: model.muted ? "Completion sounds are muted." : "Completion sounds are on.") {
                    StatusBadge(title: model.muted ? "Muted" : "On", color: model.muted ? .secondary : .green)
                }
            }

            Text("Startup").font(.headline).foregroundStyle(.secondary)
            SettingsCard {
                SettingsRow(title: "Launch at login", detail: model.launchAtLogin.detail) {
                    Toggle("Launch at login", isOn: Binding(
                        get: { model.launchAtLogin.isOn },
                        set: { enabled in model.launchAtLoginChanged(enabled) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!model.launchAtLogin.canChange)
                    .accessibilityLabel("Launch at login")
                    .accessibilityValue(model.launchAtLogin.statusTitle)
                    .accessibilityHint(model.launchAtLogin.detail)
                }
                if let statusTitle = model.launchAtLogin.settingsActionStatusTitle {
                    Divider()
                    HStack {
                        StatusBadge(title: statusTitle, color: .orange)
                        Spacer()
                        Button("Open Login Items", action: model.openLoginItemsSettings)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                if let error = model.launchAtLogin.operationError {
                    Divider()
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(16)
                        .accessibilityLabel("Launch at login error: \(error)")
                }
            }
            Text("Closing this window keeps Steer running in the menu bar.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct AgentControls: View {
    @ObservedObject var model: Companion

    var body: some View {
        ControlsPage(section: .agents) {
            Text("Connect and manage the AI agents Steer can observe.")
                .foregroundStyle(.secondary)

            Text("Available agents").font(.headline).foregroundStyle(.secondary)
            SettingsCard {
                SettingsRow(title: "Codex", detail: model.setupStatusText) {
                    StatusBadge(title: model.canUndoSetup ? "Connected" : "Not configured",
                                color: model.canUndoSetup ? .green : .orange)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.setupSurfaceStatusText.prefix(2)), id: \.self) { status in
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                    if let plan = model.setupPlan, case .ready = plan.status, plan.requiresConfigure {
                        DisclosureGroup("Show exact configuration preview") {
                            let hooks = String(data: plan.hooksChange, encoding: .utf8) ?? "(unreadable)"
                            Text("config.toml\n\(plan.configChange)\n\nhooks.json\n\(hooks)\n\nhelper command\n\(plan.helperCommand)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack {
                        Button("Review again", action: model.refreshSetup)
                        if model.canConfigureSetup {
                            Button("Configure Codex", action: model.configureCodex)
                                .buttonStyle(.borderedProminent)
                        }
                        if model.canUndoSetup { Button("Undo setup", action: model.undoCodexSetup) }
                    }
                    if !model.setupMessage.isEmpty {
                        Text(model.setupMessage).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            ClaudeAgentControls(setup: model.claude,
                                ghosttyEnabled: model.ghosttyEnabled,
                                ghosttyPermissionVerified: model.ghosttyPermissionVerified)
        }
    }
}

private struct ClaudeAgentControls: View {
    @ObservedObject var setup: ClaudeSetupModel
    let ghosttyEnabled: Bool
    let ghosttyPermissionVerified: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude Code").font(.headline).foregroundStyle(.secondary)
            Text("Each configuration root is configured independently. Steer never merges roots or changes Claude permissions.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Steer configures the selected user root. Arbitrary future project files or command-line --settings values may override it; this root-only preview cannot know those values without an exact launch context. Connection requires a fresh SessionStart from this exact root.")
                .font(.caption).foregroundStyle(.secondary)
            SettingsCard {
                ForEach(Array(setup.roots.enumerated()), id: \.element.id) { index, root in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(root.displayPath).font(.body.weight(.medium))
                                Text(ClaudeSetupModel.statusText(root.status)).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusBadge(title: root.status == .connected ? "Connected" : "Not ready",
                                        color: root.status == .connected ? .green : .orange)
                        }
                        Text(root.capabilities.version.map { "Claude Code \($0) · tested baseline \(ClaudeSetupRequirements.minimumCLIVersion)" }
                             ?? "Claude Code not detected")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(ghosttyStatusText).font(.caption).foregroundStyle(.secondary)
                        Text("Active sessions needing restart: \(root.activeSessionStatus.displayText)")
                            .font(.caption).foregroundStyle(.secondary)
                        if setup.usageEnabled(for: root) {
                            Text(usageText(root.usage, status: root.usageStatus))
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityLabel("Claude usage for \(root.displayPath): \(usageText(root.usage, status: root.usageStatus))")
                        }
                        if let plan = root.plan, case .ready = plan.status {
                            Toggle("Include optional Claude usage", isOn: Binding(
                                get: { setup.usageEnabled(for: root) },
                                set: { setup.setUsageEnabled($0, for: root) }
                            ))
                            .accessibilityLabel("Include optional Claude usage for \(root.displayPath)")
                            Text("Off by default. An existing status line is wrapped only after its cancellation compatibility probe passes.")
                                .font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("Show setup preview") {
                                let hookFields = plan.ownedHooks.map { hook in
                                    "  hooks.\(hook.event) matcher=\(hook.matcher ?? "<any>") command=\(hook.command) timeout=\(ClaudeSetupRequirements.hookTimeout)"
                                }.joined(separator: "\n")
                                let environmentFields = plan.ownedEnvironment.isEmpty
                                    ? "  env.\(ClaudeSetupRequirements.titleDisableEnvironmentKey)=\(ClaudeSetupRequirements.titleDisableEnvironmentValue) (already present; preserved)"
                                    : plan.ownedEnvironment.map { key, value in
                                        "  env.\(key)=\(value) (Steer adds and owns)"
                                    }.sorted().joined(separator: "\n")
                                let previewText = [
                                    "settings.json: \(root.settingsPath)", hookFields, environmentFields,
                                    "owned helper: \(root.helperPath)",
                                    "owned event records: \(root.eventsPath)",
                                    "owned install record: \(root.statePath)",
                                    "owned backups: \(root.backupsPath)",
                                    "SessionStart and SessionEnd title: JSON terminalSequence with the full session ID / reset",
                                    "effective scope: selected user root; arbitrary future project files or command-line --settings may override it (launch context unavailable)",
                                    "optional usage intent: \(plan.usageEnabled ? (root.usageInstalled ? "on (installed)" : "on (pending compatibility probe)") : (root.usageInstalled ? "off (remove on Configure)" : "off"))"
                                ].joined(separator: "\n")
                                Text(previewText)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack {
                                Button("Review again", action: setup.refresh)
                                    .accessibilityLabel("Review Claude setup for \(root.displayPath)")
                                if root.status != .connected || plan.requiresConfigure || root.usageInstalled != setup.usageEnabled(for: root) {
                                    Button("Configure Claude") { setup.configure(root) }
                                        .buttonStyle(.borderedProminent)
                                        .accessibilityLabel("Configure Claude for \(root.displayPath)")
                                }
                                if root.status != .notConfigured {
                                    Button("Undo setup") { setup.undo(root) }
                                        .accessibilityLabel("Undo Claude setup for \(root.displayPath)")
                                }
                                if index > 0 {
                                    Button("Remove root") { setup.removeAlternateRoot(root) }
                                        .accessibilityLabel("Remove Claude root \(root.displayPath)")
                                }
                            }
                        } else if index > 0 {
                            Button("Remove root") { setup.removeAlternateRoot(root) }
                                .accessibilityLabel("Remove Claude root \(root.displayPath)")
                        }
                    }
                    .padding(16)
                }
                Button("Add alternate Claude root", action: setup.addAlternateRoot)
                    .padding(16)
            }
            if !setup.message.isEmpty {
                Text(setup.message).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var ghosttyStatus: ClaudeGhosttyStatus {
        if !ghosttyEnabled { return .off }
        return ghosttyPermissionVerified ? .ready : .permissionRequired
    }

    private var ghosttyStatusText: String {
        switch ghosttyStatus {
        case .off: "Ghostty controls: off"
        case .permissionRequired: "Ghostty controls: permission needed"
        case .ready: "Ghostty controls: ready"
        case .unavailable(let message): "Ghostty controls: \(message)"
        }
    }

    private func usageText(_ reading: ClaudeUsageReading?, status: ClaudeUsageSetupStatus) -> String {
        if case let .unavailable(message) = status { return message }
        if case let .conflict(message) = status { return message }
        guard let reading = reading?.current(now: Date().timeIntervalSince1970) else {
            return "Claude usage: unavailable (no current subscription window reported)."
        }
        let five = reading.fiveHour.map { "5h \($0.percentText)" } ?? "5h unavailable"
        let seven = reading.sevenDay.map { "7d \($0.percentText)" } ?? "7d unavailable"
        return "Claude usage: \(five), \(seven) (last reported)"
    }
}

private struct TerminalControls: View {
    @ObservedObject var model: Companion

    var body: some View {
        ControlsPage(section: .terminals) {
            Text("Choose which terminal hosts Steer may use to return to an agent session.")
                .foregroundStyle(.secondary)

            Text("Available terminals").font(.headline).foregroundStyle(.secondary)
            SettingsCard {
                SettingsRow(title: "Ghostty", detail: "One agent session per unsplit tab.") {
                    Toggle("", isOn: $model.ghosttyEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Enable Ghostty controls")
                        .onChange(of: model.ghosttyEnabled) { _, enabled in model.ghosttyChanged(enabled) }
                }
                Divider()
                SettingsRow(title: "Automation permission", detail: automationDetail) {
                    if model.ghosttyAccess == .denied {
                        Button("Open Automation Settings", action: GhosttyAutomationPermission.openSettings)
                    }
                    StatusBadge(title: automationBadge, color: model.ghosttyPermissionVerified ? .green : .orange)
                }
                Divider()
                Text(model.setupSurfaceStatusText.last ?? "Ghostty: unavailable")
                    .font(.callout).foregroundStyle(.secondary).padding(16)
                Divider()
                HerdrControls(model: model)
            }
        }
    }

    private var automationBadge: String {
        if model.ghosttyPermissionVerified { return "Granted" }
        return model.ghosttyAccess == .denied ? "Not allowed" : "Not verified"
    }

    private var automationDetail: String {
        if model.ghosttyPermissionVerified { return "Granted in System Settings." }
        switch model.ghosttyAccess {
        case .denied: return "Not allowed. " + GhosttyAutomationPermission.deniedGuidance
        case .ghosttyNotRunning: return "Waiting for Ghostty to open; macOS asks then."
        default: return model.ghosttyEnabled ? "Waiting for macOS to confirm access." : "Enable Ghostty to let macOS request access."
        }
    }
}

/// The read-only herdr row (product.md, "Agreed herdr presentation"). It has no switch: herdr
/// works only while Ghostty controls are on. Copy places a command on the pasteboard and never
/// runs it. Exact internal reasons appear only under diagnostics, never on a notch card.
private struct HerdrControls: View {
    @ObservedObject var model: Companion
    @ObservedObject private var tty = GhosttyTTYSupportMonitor.shared

    private var row: HerdrSettingsRow {
        HerdrPresentation.settingsRow(inUse: model.herdr.inUse, ghosttyControlsEnabled: model.ghosttyEnabled,
                                      outcome: model.herdrScanOutcome, agentsSeen: model.herdrAgentsSeen,
                                      ttySupport: tty.support)
    }

    var body: some View {
        let row = row
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "herdr", detail: row.detail) {
                if let badge = row.badge {
                    StatusBadge(title: badge.title, color: color(badge))
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking herdr")
                }
            }
            if !row.problems.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(row.problems, id: \.self) { problem in
                        HerdrProblemLine(problem: problem)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
            if model.herdr.inUse, !diagnostics.isEmpty {
                DisclosureGroup("Show herdr diagnostics") {
                    Text(diagnostics.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .onAppear { tty.refreshIfStale() }
        .onChange(of: model.herdrScanOutcome) { _, _ in tty.refreshIfStale() }
    }

    private func color(_ badge: HerdrReadinessBadge) -> Color {
        switch badge {
        case .notInUse: .secondary
        case .ready: .green
        case .needsAttention: .orange
        }
    }

    /// The scan's exact reason and each queued herdr session's exact reasons: Open's availability,
    /// its latest failed click-time Open, and why each queued Codex question cannot be relayed.
    private var diagnostics: [String] {
        var lines: [String] = []
        if case .unavailable(let reason) = model.herdrScanOutcome { lines.append("scan: \(reason)") }
        var seen: Set<AgentSessionIdentity> = []
        for item in model.orderedAgentAttentionItems {
            let label = "\(item.session.source.rawValue) \(item.session.session.prefix(8))"
            if let question = item.question.flatMap(model.codexQuestion(for:)),
               let reason = model.herdrRelayUnavailable(for: question) {
                lines.append("\(label) question \(question.callID): \(HerdrUnavailableCause.relay(reason).diagnostic)")
            }
            guard seen.insert(item.session).inserted else { continue }
            if case .unavailable(let cause) = model.herdrOpenAvailability(item.session, ttySupport: tty.support) {
                lines.append("\(label): \(cause.diagnostic)")
            }
            if let key = model.herdrSessionKey(item.session), let failure = model.herdrOpenFailure(for: key) {
                lines.append("\(label): \(HerdrUnavailableCause.open(failure).diagnostic)")
            }
        }
        return lines
    }
}

private struct HerdrProblemLine: View {
    let problem: HerdrSettingsProblem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(problem.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            }
            if let command = problem.command {
                HStack(spacing: 10) {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .accessibilityLabel("Copy \(command)")
                    .accessibilityHint("Copies the command. Steer does not run it.")
                }
                .padding(.leading, 28)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct NotificationControls: View {
    @ObservedObject var model: Companion

    var body: some View {
        ControlsPage(section: .notifications) {
            Text("Control how Steer presents work that needs your attention.")
                .foregroundStyle(.secondary)

            SettingsCard {
                SettingsRow(title: "Play completion sound", detail: "Plays once for each newly presented completion.") {
                    Toggle("", isOn: Binding(get: { !model.muted }, set: { enabled in model.setSoundEnabled(enabled) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Play completion sound")
                }
                Divider()
                SettingsRow(title: "Clear completions marked read", detail: "Reads Codex's own desktop read state; Steer never marks a task read.") {
                    Toggle("", isOn: $model.desktopReadStateEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Clear completions marked read")
                        .onChange(of: model.desktopReadStateEnabled) { _, enabled in model.desktopReadStateChanged(enabled) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.desktopReadStateMessage).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Send test notification", action: model.sendTest)
                        Button("Dismiss test", action: model.dismissTest).disabled(!model.attention.pending)
                    }
                }
                .padding(16)
            }
        }
    }
}

private struct AdvancedControls: View {
    @ObservedObject var model: Companion

    var body: some View {
        ControlsPage(section: .advanced) {
            Text("Diagnostics and integration details for troubleshooting Steer.")
                .foregroundStyle(.secondary)

            Text("Event delivery").font(.headline).foregroundStyle(.secondary)
            SettingsCard {
                SettingsRow(title: "Agent events", detail: model.eventsPath.isEmpty ? "Not connected." : model.eventsPath) {
                    Button("Choose…", action: model.connectReminders)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.daemonStatus).font(.callout)
                    Text("Steer connects only to a daemon that is already running; it never starts one.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(16)
            }

            Text("Task-link check").font(.headline).foregroundStyle(.secondary)
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Local Codex task ID", text: $model.taskID)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Local Codex task ID")
                        Button("Open task", action: model.openTestTask).disabled(model.openingTask)
                    }
                    Text(model.navigationMessage.isEmpty ? "Opening a task does not dismiss its notification." : model.navigationMessage)
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
    }
}

private struct AboutControls: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }

    var body: some View {
        ControlsPage(section: .about) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Steer").font(.title2.bold())
                Text("Keeps agent activity and requests within reach while you work.")
                    .foregroundStyle(.secondary)
                Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
            }
            Text("Steer currently supports Codex and Ghostty. Other agent and terminal integrations appear only when they are implemented.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
