import AppKit
import SwiftUI
import SteerCore

private enum ControlSection: String, CaseIterable, Identifiable {
    case general
    case notch
    case notifications
    case agents
    case terminals
    case about

    var id: Self { self }
    var title: String { rawValue.capitalized }
    /// The Notch tile draws the green sprite instead of a symbol (DESIGN.md, Settings Window).
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .notch: ""
        case .agents: "sparkles"
        case .terminals: "apple.terminal.fill"
        case .notifications: "bell.fill"
        case .about: "info.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .general: .gray
        case .notch: .black
        case .agents: .purple
        case .terminals: Color(white: 0.22)
        case .notifications: .red
        case .about: .blue
        }
    }
}

/// Native grouped-form metrics measured on macOS 26; see DESIGN.md, Settings Window.
/// In dark mode the window takes a near-black tint, closer to the notch, with sections one step
/// lighter; light mode keeps the system's measured values.
enum SettingsStyle {
    static func dynamic(dark: CGFloat, light: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
        }
    }
    static let windowBackground = dynamic(dark: 0.075, light: 1)
    static let pageBackground = Color(nsColor: windowBackground)
    static let sectionFill = Color(nsColor: dynamic(dark: 0.125, light: 0.976))
    static let sidebarFill = Color(nsColor: dynamic(dark: 0.11, light: 0.93))
    static let rowInset: CGFloat = 10
}

/// Settings-window feedback: every click answers within about half a second with a smooth ease, and
/// Reduce Motion keeps only a short crossfade with no movement. The notch keeps its own motion rules.
private enum SettingsMotion {
    static func curve(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.4)
    }

    static func pageTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity)
    }
}

/// A soft click for settings choices. It follows the system's "Play user interface sound effects"
/// setting, so turning that off in System Settings silences it.
@MainActor
private enum SettingsClick {
    private static let sound: NSSound? = {
        let sound = NSSound(named: "Tink")?.copy() as? NSSound
        sound?.volume = 0.3
        return sound
    }()

    private static var enabled: Bool {
        let defaults = UserDefaults(suiteName: "com.apple.systemsound")
        return (defaults?.object(forKey: "com.apple.sound.uiaudio.enabled") as? Int ?? 1) != 0
    }

    static func play() {
        guard enabled, let sound else { return }
        sound.stop()
        sound.play()
    }
}

/// A light press: the control dips to 97% and dims slightly, then eases back.
private struct PressFeedback: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.smooth(duration: 0.2), value: configuration.isPressed)
    }
}

struct Controls: View {
    @ObservedObject var model: Companion
    @State private var selection: ControlSection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: Companion) {
        self.model = model
        // This is an intentional one-time navigation seed: restore the user's last section, then
        // let setup lead on a fresh install until an agent is connected.
        let saved = UserDefaults.standard.string(forKey: "controlsSection").flatMap(ControlSection.init(rawValue:))
        _selection = State(initialValue: saved ?? (model.canUndoSetup ? .general : .agents))
    }

    var body: some View {
        // A fixed sidebar panel that runs the full window height, so the window buttons sit inside
        // it as in System Settings and Raycast. It never collapses.
        HStack(spacing: 0) {
            ControlsSidebar(selection: $selection, status: "\(model.workingCount) working · \(model.currentToCheckCount) to check")
                .frame(width: 210)
                .padding(8)
            ZStack {
                ControlsDetail(section: selection, model: model)
                    .id(selection)
                    .transition(SettingsMotion.pageTransition(reduceMotion: reduceMotion))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(SettingsMotion.curve(reduceMotion: reduceMotion), value: selection)
        }
        .ignoresSafeArea()
        .background(SettingsStyle.pageBackground)
        .frame(minWidth: 720, minHeight: 600)
        .onChange(of: selection) { _, section in
            SettingsClick.play()
            UserDefaults.standard.set(section.rawValue, forKey: "controlsSection")
        }
    }
}

private struct ControlsSidebar: View {
    @Binding var selection: ControlSection
    let status: String

    var body: some View {
        List(selection: $selection) {
            Section("Notch") {
                ForEach([ControlSection.general, .notch, .notifications]) { section in
                    SidebarLabel(section: section).tag(section)
                }
            }
            Section("Connections") {
                ForEach([ControlSection.agents, .terminals]) { section in
                    SidebarLabel(section: section).tag(section)
                }
            }
            Section {
                SidebarLabel(section: .about).tag(ControlSection.about)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Room for the window buttons, which the window draws over the panel's top edge.
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 36) }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 7) {
                Circle().fill(.green).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(status).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
        }
        .background(SettingsStyle.sidebarFill, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

private struct SidebarLabel: View {
    let section: ControlSection

    var body: some View {
        Label {
            Text(section.title)
        } icon: {
            Group {
                if section == .notch {
                    Sprite(working: false, reduceMotion: true)
                } else {
                    Image(systemName: section.symbol).font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(section.color, in: .rect(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
        }
    }
}

private struct ControlsDetail: View {
    let section: ControlSection
    @ObservedObject var model: Companion

    var body: some View {
        switch section {
        case .general: GeneralControls(model: model)
        case .notch: NotchControls(model: model)
        case .agents: AgentControls(model: model)
        case .terminals: TerminalControls(model: model)
        case .notifications: NotificationControls(model: model)
        case .about: AboutControls(quit: model.quit)
        }
    }
}

/// A pane: its title row sits in the window's title bar beside the traffic lights, with an optional
/// control at its trailing edge, and the grouped sections scroll beneath it.
private struct ControlsPage<Accessory: View, Content: View>: View {
    let section: ControlSection
    let accessory: Accessory
    let content: Content

    init(section: ControlSection, @ViewBuilder content: () -> Content) where Accessory == EmptyView {
        self.section = section
        self.accessory = EmptyView()
        self.content = content()
    }

    init(section: ControlSection, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.section = section
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(section.title).font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                accessory
            }
            .padding(.leading, 24)
            .padding(.trailing, 20)
            .frame(height: 52)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .font(.body)
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 20)
                .background(OverlayScroller())
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(SettingsStyle.pageBackground)
        .navigationTitle(section.title)
    }
}

/// Gives the enclosing scroll view a small overlay scroller that appears only while scrolling, even
/// when a connected mouse makes macOS default to always-visible scroll bars. Reapplied when the
/// system's preferred style changes, because AppKit resets it then.
private struct OverlayScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil else { return }
            apply()
            observer = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // AppKit updates its own scroll views on the same notification; apply after it.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply() } }
            }
        }

        private func apply() {
            guard let scrollView = enclosingScrollView else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            // The small scroller draws a thinner knob that still widens when the pointer is over it.
            scrollView.verticalScroller?.controlSize = .small
        }
    }
}

/// A segmented choice whose accent highlight slides to the chosen segment over 0.4 s, where the
/// system segmented control would jump. VoiceOver reads it as the native segmented picker.
private struct SlidingSegments<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    @Namespace private var highlight
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let chosen = option.value == selection
                Button {
                    if option.value != selection { SettingsClick.play() }
                    withAnimation(SettingsMotion.curve(reduceMotion: reduceMotion)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: chosen ? .medium : .regular))
                        .foregroundStyle(chosen ? Color.white : Color.primary)
                        .padding(.horizontal, 12)
                        .frame(height: 20)
                        .background {
                            if chosen {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isEnabled ? Color.accentColor : Color.secondary.opacity(0.45))
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressFeedback())
            }
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .fixedSize()
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.value) { option in Text(option.label).tag(option.value) }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// A menu picker drawn the way a grouped form draws one: the value, then a round chevron button.
private struct FormMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    private var current: String { options.first { $0.value == selection }?.label ?? "" }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.value) { option in Text(option.label).tag(option.value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(current).foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(.quaternary, in: Circle())
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(current)
    }
}

/// A grouped section: system fill, 12pt continuous corners, no border.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(SettingsStyle.sectionFill, in: .rect(cornerRadius: 12, style: .continuous))
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
    }
}

/// A section header (13pt bold) aligned with the row text, with room above it for the previous footer.
private struct SettingsHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.headline)
            .padding(.horizontal, SettingsStyle.rowInset)
            .padding(.top, 18)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A section footer: 11pt secondary text explaining the section above.
private struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SettingsStyle.rowInset)
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, SettingsStyle.rowInset)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
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

    /// nil while a setup is still being checked, so the row reads "Checking" rather than guessing.
    private var codexConnected: Bool? { model.setupChecked ? model.setupStatus == .connected : nil }
    private var claudeConnected: Bool? {
        model.claude.checked ? model.claude.roots.contains { $0.status == .connected } : nil
    }

    var body: some View {
        ControlsPage(section: .general) {
            SettingsHeader("Status")
            SettingsCard {
                SettingsRow(title: "Codex", detail: nil) { connection(codexConnected) }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Claude Code", detail: nil) { connection(claudeConnected) }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Sessions", detail: nil) {
                    Text("\(model.workingCount) working · \(model.currentToCheckCount) to check").foregroundStyle(.secondary)
                }
            }

            SettingsHeader("Display")
            SettingsCard {
                SettingsRow(title: "Show notch on", detail: model.notchDisplayChoices.detail) {
                    FormMenu(title: "Show notch on", selection: Binding(
                        get: { model.notchDisplayChoices.selected.preference },
                        set: { preference in model.setNotchDisplayPreference(preference) }
                    ), options: model.notchDisplayChoices.options.map { ($0.preference, $0.label) })
                    .accessibilityHint(model.notchDisplayChoices.detail)
                }
            }

            SettingsHeader("Startup")
            SettingsCard {
                SettingsRow(title: "Launch at login", detail: model.launchAtLogin.detail) {
                    Toggle("Launch at login", isOn: Binding(
                        get: { model.launchAtLogin.isOn },
                        set: { enabled in model.launchAtLoginChanged(enabled) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!model.launchAtLogin.canChange)
                    .accessibilityLabel("Launch at login")
                    .accessibilityValue(model.launchAtLogin.statusTitle)
                    .accessibilityHint(model.launchAtLogin.detail)
                }
                if let statusTitle = model.launchAtLogin.settingsActionStatusTitle {
                    Divider().padding(.horizontal, SettingsStyle.rowInset)
                    HStack {
                        StatusBadge(title: statusTitle, color: .orange)
                        Spacer()
                        Button("Open Login Items", action: model.openLoginItemsSettings)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                if let error = model.launchAtLogin.operationError {
                    Divider().padding(.horizontal, SettingsStyle.rowInset)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(16)
                        .accessibilityLabel("Launch at login error: \(error)")
                }
            }
            SettingsHeader("Behavior")
            SettingsCard {
                SettingsRow(title: "Keep new cards open until I act", detail: "Instead of closing after 3 seconds") {
                    Toggle("Keep new cards open until I act", isOn: $model.keepCardsOpen)
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Haptic feedback on hover", detail: nil) {
                    Toggle("Haptic feedback on hover", isOn: $model.hapticFeedback)
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }
            SettingsFooter("Keeping a card open never extends an approval. Each request still hands back to its agent 30 seconds after it arrives. Closing this window keeps Steer running in the menu bar.")
        }
    }

    private func connection(_ connected: Bool?) -> some View {
        switch connected {
        case true?: StatusBadge(title: "Connected", color: .green)
        case false?: StatusBadge(title: "Not connected", color: .orange)
        case nil: StatusBadge(title: "Checking", color: .secondary)
        }
    }
}

private struct AgentControls: View {
    @ObservedObject var model: Companion

    private var capabilities: CodexCapabilities { model.setupCapabilities }

    var body: some View {
        ControlsPage(section: .agents) {
            SettingsHeader("Codex")
            SettingsCard {
                SettingsRow(title: "Status", detail: model.canUndoSetup ? nil : model.setupStatusText) {
                    StatusBadge(title: model.canUndoSetup ? "Connected" : "Not configured",
                                color: model.canUndoSetup ? .green : .orange)
                }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Codex CLI", detail: nil) {
                    Text(Self.version(installed: capabilities.cliInstalled, supported: capabilities.cli,
                                      version: capabilities.cliVersion, minimum: CodexSetupRequirements.minimumCLIVersion))
                        .foregroundStyle(.secondary)
                }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Codex desktop", detail: nil) {
                    Text(Self.version(installed: capabilities.desktopInstalled, supported: capabilities.desktop,
                                      version: capabilities.desktopVersion, minimum: CodexSetupRequirements.minimumDesktopVersion))
                        .foregroundStyle(.secondary)
                }
                if let plan = model.setupPlan, case .ready = plan.status, plan.requiresConfigure {
                    Divider().padding(.horizontal, SettingsStyle.rowInset)
                    PreviewDisclosure(title: "Show configuration changes") {
                        let hooks = String(data: plan.hooksChange, encoding: .utf8) ?? "(unreadable)"
                        return "config.toml\n\(plan.configChange)\n\nhooks.json\n\(hooks)\n\nhelper command\n\(plan.helperCommand)"
                    }
                }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                ActionRow {
                    if model.canUndoSetup { Button("Undo Setup…", action: model.undoCodexSetup) }
                    Button("Review Again", action: model.refreshSetup)
                    if model.canConfigureSetup {
                        Button("Configure Codex", action: model.configureCodex).buttonStyle(.borderedProminent)
                    }
                }
            }
            if !model.setupMessage.isEmpty { SettingsFooter(model.setupMessage) }

            ClaudeAgentControls(setup: model.claude,
                                ghosttyEnabled: model.ghosttyEnabled,
                                ghosttyPermissionVerified: model.ghosttyPermissionVerified)
        }
    }

    /// A surface's version as the row's value: the version when it is supported, otherwise why not.
    static func version(installed: Bool, supported: Bool, version: String?, minimum: String) -> String {
        guard installed else { return "Not installed" }
        guard supported else { return "\(version ?? "Unknown version") · needs \(minimum) or later" }
        return version ?? "Installed"
    }
}

/// Buttons at the trailing edge of a section's last row.
private struct ActionRow<Buttons: View>: View {
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            buttons
        }
        .padding(.horizontal, SettingsStyle.rowInset)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

/// A row that reveals exact, selectable text such as a configuration preview.
private struct PreviewDisclosure: View {
    let title: String
    let text: () -> String

    var body: some View {
        DisclosureGroup(title) {
            Text(text())
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
        .padding(.horizontal, SettingsStyle.rowInset)
        .padding(.vertical, 9)
    }
}

private struct ClaudeAgentControls: View {
    @ObservedObject var setup: ClaudeSetupModel
    let ghosttyEnabled: Bool
    let ghosttyPermissionVerified: Bool

    var body: some View {
        SettingsHeader("Claude Code")
        ForEach(Array(setup.roots.enumerated()), id: \.element.id) { index, root in
            SettingsCard {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(root.displayPath).font(.system(.body, design: .monospaced))
                        Text(rootSummary(root, isDefault: index == 0)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    StatusBadge(title: root.status == .connected ? "Connected" : "Not ready",
                                color: root.status == .connected ? .green : .orange)
                }
                .padding(.horizontal, SettingsStyle.rowInset)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Sessions", detail: nil) {
                    Text(root.activeSessionStatus.displayText).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                if let plan = root.plan, case .ready = plan.status {
                    Divider().padding(.horizontal, SettingsStyle.rowInset)
                    SettingsRow(title: "Include usage limits",
                                detail: setup.usageEnabled(for: root)
                                    ? usageText(root.usage, status: root.usageStatus)
                                    : "Shows Claude's 5-hour and weekly limits on the strip") {
                        Toggle("Include usage limits", isOn: Binding(
                            get: { setup.usageEnabled(for: root) },
                            set: { setup.setUsageEnabled($0, for: root) }
                        ))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .accessibilityLabel("Include Claude usage limits for \(root.displayPath)")
                    }
                    Divider().padding(.horizontal, SettingsStyle.rowInset)
                    SettingsRow(title: "Name sessions with Haiku",
                                detail: "Replaces a placeholder name like project-a2 with a title from the first prompt, applied on the next prompt") {
                        Toggle("Name sessions with Haiku", isOn: Binding(
                            get: { setup.sessionTitlesEnabled(for: root) },
                            set: { setup.setSessionTitlesEnabled($0, for: root) }
                        ))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .accessibilityLabel("Name Claude sessions with Haiku for \(root.displayPath)")
                    }
                    Divider().padding(.horizontal, SettingsStyle.rowInset)
                    PreviewDisclosure(title: "Show setup changes") { previewText(root, plan: plan) }
                    if plan.addsHooks, root.status == .connected || { if case .configuredAwaitingRestart = root.status { return true }; return false }() {
                        // A connected root missing newer Steer hooks (such as file approvals) keeps working;
                        // those requests stay in Claude until the user reconfigures.
                        Divider().padding(.horizontal, SettingsStyle.rowInset)
                        Text("This version of Steer adds Claude hooks, such as file approvals. Configure Claude to add them; until then those requests stay in Claude.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, SettingsStyle.rowInset).padding(.vertical, 6)
                    }
                    Divider().padding(.horizontal, SettingsStyle.rowInset)
                    ActionRow {
                        if index > 0 {
                            Button("Remove Root") { setup.removeAlternateRoot(root) }
                                .accessibilityLabel("Remove Claude root \(root.displayPath)")
                        }
                        if root.status != .notConfigured {
                            Button("Undo Setup…") { setup.undo(root) }
                                .accessibilityLabel("Undo Claude setup for \(root.displayPath)")
                        }
                        Button("Review Again", action: setup.refresh)
                            .accessibilityLabel("Review Claude setup for \(root.displayPath)")
                        if root.status != .connected || plan.requiresConfigure || root.usageInstalled != setup.usageEnabled(for: root) {
                            Button("Configure Claude") { setup.configure(root) }
                                .buttonStyle(.borderedProminent)
                                .accessibilityLabel("Configure Claude for \(root.displayPath)")
                        }
                    }
                } else if index > 0 {
                    Divider().padding(.horizontal, SettingsStyle.rowInset)
                    ActionRow {
                        Button("Remove Root") { setup.removeAlternateRoot(root) }
                            .accessibilityLabel("Remove Claude root \(root.displayPath)")
                    }
                }
            }
        }
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Using CLAUDE_CONFIG_DIR? Add each extra root. Steer configures only the root you choose, never merges roots, and never changes Claude permissions; project files or --settings flags can still override it.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Add Claude Root…", action: setup.addAlternateRoot)
        }
        .padding(.horizontal, SettingsStyle.rowInset)
        if !setup.message.isEmpty { SettingsFooter(setup.message) }
    }

    private func rootSummary(_ root: ClaudeSetupModel.Root, isDefault: Bool) -> String {
        let version = root.capabilities.version.map { "Claude Code \($0)" } ?? "Claude Code not detected"
        return [isDefault ? "Default root" : "Alternate root", version, ghosttyStatusText].joined(separator: " · ")
    }

    private func previewText(_ root: ClaudeSetupModel.Root, plan: ClaudeSetupPlan) -> String {
        let hookFields = plan.ownedHooks.map { hook in
            "  hooks.\(hook.event) matcher=\(hook.matcher ?? "<any>") command=\(hook.command) timeout=\(ClaudeSetupRequirements.hookTimeout)"
        }.joined(separator: "\n")
        let environmentFields = plan.ownedEnvironment.isEmpty
            ? "  env.\(ClaudeSetupRequirements.titleDisableEnvironmentKey)=\(ClaudeSetupRequirements.titleDisableEnvironmentValue) (already present; preserved)"
            : plan.ownedEnvironment.map { key, value in
                "  env.\(key)=\(value) (Steer adds and owns)"
            }.sorted().joined(separator: "\n")
        return [
            "settings.json: \(root.settingsPath)", hookFields, environmentFields,
            "owned helper: \(root.helperPath)",
            "owned event records: \(root.eventsPath)",
            "owned install record: \(root.statePath)",
            "owned backups: \(root.backupsPath)",
            "SessionStart and SessionEnd title: JSON terminalSequence with the full session ID / reset",
            "effective scope: selected user root; arbitrary future project files or command-line --settings may override it (launch context unavailable)",
            "optional usage intent: \(plan.usageEnabled ? (root.usageInstalled ? "on (installed)" : "on (pending compatibility probe)") : (root.usageInstalled ? "off (remove on Configure)" : "off"))"
        ].joined(separator: "\n")
    }

    private var ghosttyStatus: ClaudeGhosttyStatus {
        if !ghosttyEnabled { return .off }
        return ghosttyPermissionVerified ? .ready : .permissionRequired
    }

    private var ghosttyStatusText: String {
        switch ghosttyStatus {
        case .off: "Ghostty off"
        case .permissionRequired: "Ghostty permission needed"
        case .ready: "Ghostty ready"
        case .unavailable(let message): "Ghostty: \(message)"
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
            SettingsHeader("Terminals")
            ForEach(TerminalHost.terminals.filter(\.showsCard), id: \.self, content: card)
            SettingsHeader("Multiplexers")
            ForEach(TerminalHost.multiplexers.filter(\.showsCard), id: \.self, content: card)
        }
    }

    /// A host's card. Each host's acceptance ticket adds its card here and turns on `showsCard`.
    @ViewBuilder
    private func card(_ host: TerminalHost) -> some View {
        switch host {
        case .ghostty: ghosttyCard
        case .herdr: HerdrControls(model: model)
        case .iTerm2: ITerm2Controls(model: model, state: model.iTerm2)
        case .terminalApp: TerminalAppControls(model: model)
        case .wezTerm: WezTermControls(model: model, state: model.wezTerm)
        case .tmux: TmuxControls(model: model, state: model.tmux)
        case .zellij: ZellijControls(model: model, state: model.zellij)
        }
    }

    @ViewBuilder
    private var ghosttyCard: some View {
        SettingsCard {
            SettingsRow(title: TerminalHost.ghostty.displayName, detail: "Open sessions in their exact tab, and answer questions there") {
                Toggle("Ghostty controls", isOn: $model.ghosttyEnabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .accessibilityLabel("Enable Ghostty controls")
                    .onChange(of: model.ghosttyEnabled) { _, enabled in model.ghosttyChanged(enabled) }
            }
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            SettingsRow(title: "Version", detail: nil) {
                Text(AgentControls.version(installed: model.setupCapabilities.ghosttyInstalled,
                                           supported: model.setupCapabilities.ghostty,
                                           version: model.setupCapabilities.ghosttyVersion,
                                           minimum: CodexSetupRequirements.minimumGhosttyVersion))
                    .foregroundStyle(.secondary)
            }
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            SettingsRow(title: "Automation permission",
                        detail: model.ghosttyPermissionVerified ? nil : automationDetail) {
                HStack(spacing: 10) {
                    if model.ghosttyAccess == .denied {
                        Button("Open Settings…", action: GhosttyAutomationPermission.openSettings)
                    }
                    StatusBadge(title: automationBadge, color: model.ghosttyPermissionVerified ? .green : .orange)
                }
            }
        }
        SettingsFooter("Steer targets only unsplit tabs it can match exactly. If a tab is split, closed, or duplicated, Open Session reports it unavailable instead of guessing.")
    }

    private var automationBadge: String {
        if model.ghosttyPermissionVerified { return "Allowed" }
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

/// The Terminal.app card (product.md, "Agreed terminal host presentation"; #239), shown since
/// Terminal.app's acceptance run passed (#244, `TerminalHost.showsCard`).
private struct TerminalAppControls: View {
    @ObservedObject var model: Companion

    var body: some View {
        let row = model.terminalAppSettingsRow
        SettingsCard {
            SettingsRow(title: TerminalHost.terminalApp.displayName, detail: "Open sessions in their exact tab, and type replies there") {
                Toggle("Terminal.app", isOn: Binding(get: { model.hostSwitches.isOn(.terminalApp) },
                                                     set: { model.setHostSwitch(.terminalApp, on: $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .accessibilityLabel("Enable Terminal.app")
            }
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            SettingsRow(title: "Version", detail: nil) {
                Text(model.terminalApp.version ?? "Not installed").foregroundStyle(.secondary)
            }
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            SettingsRow(title: "Automation permission", detail: nil) {
                HStack(spacing: 10) {
                    if model.terminalApp.shownAccess == .denied {
                        Button("Open Settings…", action: GhosttyAutomationPermission.openSettings)
                    }
                    StatusBadge(title: row.permission, color: row.permission == "Allowed" ? .green : .orange)
                }
            }
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            SettingsRow(title: "Status", detail: row.detail) {
                StatusBadge(title: row.badge.title, color: row.badge == .ready ? .green : row.badge == .needsAttention ? .orange : .secondary)
            }
            ForEach(row.problems, id: \.self) { problem in
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: problem, detail: nil) { EmptyView() }
            }
            if !model.terminalApp.diagnostics.isEmpty {
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                PreviewDisclosure(title: "Show diagnostics") { model.terminalApp.diagnostics.joined(separator: "\n") }
            }
        }
        SettingsFooter(TerminalAppPresentation.footer)
    }
}

/// The WezTerm card (product.md, "Agreed terminal host presentation"; #240), shown since WezTerm's
/// acceptance run passed (#245, `TerminalHost.showsCard`). WezTerm needs no Automation access, so the card
/// has no Permission row.
private struct WezTermControls: View {
    @ObservedObject var model: Companion
    @ObservedObject var state: WezTermState

    var body: some View {
        let row = model.wezTermSettingsRow
        SettingsCard {
            SettingsRow(title: TerminalHost.wezTerm.displayName, detail: "Open sessions in their exact tab, and type replies there") {
                Toggle("WezTerm", isOn: Binding(get: { model.hostSwitches.isOn(.wezTerm) },
                                                set: { model.setHostSwitch(.wezTerm, on: $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .accessibilityLabel("Enable WezTerm")
            }
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            SettingsRow(title: "Version", detail: nil) {
                Text(state.installed ? state.version ?? "Unknown" : "Not installed").foregroundStyle(.secondary)
            }
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            SettingsRow(title: "Status", detail: nil) {
                StatusBadge(title: row.badge.title,
                            color: row.badge == .ready ? .green : row.badge == .needsAttention ? .orange : .secondary)
            }
            ForEach(row.problems, id: \.self) { problem in
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                Text(problem.message).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsStyle.rowInset)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.hostSwitches.isOn(.wezTerm), !state.diagnostics.isEmpty {
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                PreviewDisclosure(title: "Show diagnostics") { state.diagnostics.joined(separator: "\n") }
            }
        }
        SettingsFooter(WezTermPresentation.footer)
    }
}

/// The tmux card (product.md, "Agreed terminal host presentation"; #241). Shown only once
/// `TerminalHost.tmux.showsCard` is turned on by its acceptance (#246). tmux has no Permission row.
private struct TmuxControls: View {
    @ObservedObject var model: Companion
    @ObservedObject var state: TmuxState

    var body: some View {
        let row = model.tmuxSettingsRow
        SettingsCard {
            SettingsRow(title: TerminalHost.tmux.displayName, detail: "Open sessions in their exact pane, and type replies there") {
                Toggle("tmux", isOn: Binding(get: { model.hostSwitches.isOn(.tmux) },
                                             set: { model.setHostSwitch(.tmux, on: $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .accessibilityLabel("Enable tmux")
            }
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            SettingsRow(title: "Status", detail: row.detail) {
                StatusBadge(title: row.badge.title, color: row.badge == .ready ? .green : row.badge == .needsAttention ? .orange : .secondary)
            }
            ForEach(row.problems, id: \.self) { problem in
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                Text(problem).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsStyle.rowInset)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.hostSwitches.isOn(.tmux), !state.diagnostics.isEmpty {
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                PreviewDisclosure(title: "Show diagnostics") { state.diagnostics.joined(separator: "\n") }
            }
        }
        SettingsFooter(TmuxPresentation.footer)
    }
}

/// The Zellij card (product.md, "Agreed terminal host presentation"; #242). Shown only once
/// `TerminalHost.zellij.showsCard` is turned on by its acceptance (#247). Zellij has no Permission row.
private struct ZellijControls: View {
    @ObservedObject var model: Companion
    @ObservedObject var state: ZellijState

    var body: some View {
        let row = model.zellijSettingsRow
        SettingsCard {
            SettingsRow(title: TerminalHost.zellij.displayName, detail: "Open sessions in their exact pane, and type replies there") {
                Toggle("Zellij", isOn: Binding(get: { model.hostSwitches.isOn(.zellij) },
                                               set: { model.setHostSwitch(.zellij, on: $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .accessibilityLabel("Enable Zellij")
            }
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            SettingsRow(title: "Status", detail: row.detail) {
                StatusBadge(title: row.badge.title, color: row.badge == .ready ? .green : row.badge == .needsAttention ? .orange : .secondary)
            }
            ForEach(row.problems, id: \.self) { problem in
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                Text(problem).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsStyle.rowInset)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.hostSwitches.isOn(.zellij), !state.diagnostics.isEmpty {
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                PreviewDisclosure(title: "Show diagnostics") { state.diagnostics.joined(separator: "\n") }
            }
        }
        SettingsFooter(ZellijPresentation.footer)
    }
}

/// The herdr card (product.md, "Agreed terminal host presentation"). Its switch is herdr's own;
/// Steer contacts herdr only while it and a terminal are on. Copy places a command on the
/// pasteboard and never runs it. Exact internal reasons appear only under diagnostics, never on a
/// notch card.
private struct HerdrControls: View {
    @ObservedObject var model: Companion
    @ObservedObject private var tty = GhosttyTTYSupportMonitor.shared

    private var row: HerdrSettingsRow {
        HerdrPresentation.settingsRow(switches: model.hostSwitches, inUse: model.herdr.inUse,
                                      outcome: model.herdrScanOutcome, agentsSeen: model.herdrAgentsSeen,
                                      ttySupport: tty.support)
    }

    var body: some View {
        let row = row
        SettingsCard {
            SettingsRow(title: TerminalHost.herdr.displayName, detail: "Open sessions in their exact pane, and answer questions there") {
                Toggle("herdr", isOn: Binding(get: { model.hostSwitches.isOn(.herdr) },
                                              set: { model.setHostSwitch(.herdr, on: $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .accessibilityLabel("Enable herdr")
            }
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            SettingsRow(title: "Status", detail: nil) {
                if let badge = row.badge {
                    StatusBadge(title: badge.title, color: color(badge))
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking herdr")
                }
            }
            ForEach(row.problems, id: \.self) { problem in
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                HerdrProblemLine(problem: problem)
            }
            if model.herdr.inUse, !diagnostics.isEmpty {
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                PreviewDisclosure(title: "Show diagnostics") { diagnostics.joined(separator: "\n") }
            }
        }
        .onAppear { tty.refreshIfStale() }
        .onChange(of: model.herdrScanOutcome) { _, _ in tty.refreshIfStale() }
        SettingsFooter(row.detail)
    }

    private func color(_ badge: HerdrReadinessBadge) -> Color {
        switch badge {
        case .off, .notInUse: .secondary
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

/// The iTerm2 card (product.md, "Agreed terminal host presentation"), shown since iTerm2's acceptance
/// run passed (#243, `TerminalHost.showsCard`). Its switch asks macOS for Automation access as Ghostty's does.
private struct ITerm2Controls: View {
    @ObservedObject var model: Companion
    @ObservedObject var state: ITerm2State

    private var row: ITerm2SettingsRow {
        ITerm2Presentation.settingsRow(on: model.hostSwitches.isOn(.iTerm2), installed: state.installed,
                                       access: state.access, scan: state.scan, inUse: state.inUse)
    }

    var body: some View {
        let row = row
        SettingsCard {
            SettingsRow(title: TerminalHost.iTerm2.displayName, detail: "Open sessions in their exact tab") {
                Toggle("iTerm2", isOn: Binding(get: { model.hostSwitches.isOn(.iTerm2) },
                                               set: { model.setHostSwitch(.iTerm2, on: $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .accessibilityLabel("Enable iTerm2")
            }
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            SettingsRow(title: "Version", detail: nil) {
                Text(state.installed ? (state.version ?? "Installed") : "Not installed").foregroundStyle(.secondary)
            }
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            SettingsRow(title: "Automation permission", detail: nil) {
                HStack(spacing: 10) {
                    if state.access == .denied {
                        Button("Open Settings…", action: GhosttyAutomationPermission.openSettings)
                    }
                    StatusBadge(title: row.permission, color: state.access == .granted ? .green : .orange)
                }
            }
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            SettingsRow(title: "Status", detail: nil) {
                StatusBadge(title: row.badge.title, color: color(row.badge))
            }
            ForEach(row.problems, id: \.self) { problem in
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                Text(problem.message).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsStyle.rowInset)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !diagnostics.isEmpty {
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                PreviewDisclosure(title: "Show diagnostics") { diagnostics.joined(separator: "\n") }
            }
        }
        SettingsFooter(ITerm2Presentation.footer)
    }

    private func color(_ badge: HerdrReadinessBadge) -> Color {
        switch badge {
        case .off, .notInUse: .secondary
        case .ready: .green
        case .needsAttention: .orange
        }
    }

    /// The scan's result and each session's latest Open in iTerm2 with its exact reason. Typed input is
    /// always unavailable there (ADR 0017).
    private var diagnostics: [String] {
        guard model.hostSwitches.isOn(.iTerm2) else { return [] }
        var lines = ["scan: \(state.scan)", "typed input: none (ADR 0017)"]
        for (session, line) in state.lastOpen.sorted(by: { $0.key < $1.key }) {
            lines.append("\(session.prefix(8)): \(line)")
        }
        return lines
    }
}

private struct HerdrProblemLine: View {
    let problem: HerdrSettingsProblem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(problem.message).fixedSize(horizontal: false, vertical: true)
            if let command = problem.command {
                HStack(spacing: 12) {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(.quaternary, in: .rect(cornerRadius: 6, style: .continuous))
                    Spacer(minLength: 8)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .accessibilityLabel("Copy \(command)")
                    .accessibilityHint("Copies the command. Steer does not run it.")
                }
            }
        }
        .padding(.horizontal, SettingsStyle.rowInset)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }
}

private struct NotificationControls: View {
    @ObservedObject var model: Companion
    private let sounds = Companion.systemSoundNames

    var body: some View {
        ControlsPage(section: .notifications) {
            SettingsHeader("Sound")
            SettingsCard {
                SettingsRow(title: "Play a sound for new completions and questions", detail: nil) {
                    Toggle("Play a sound for new completions and questions",
                           isOn: Binding(get: { !model.muted }, set: { enabled in
                               withAnimation(SettingsMotion.curve(reduceMotion: model.reduceMotion)) { model.setSoundEnabled(enabled) }
                           }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                VStack(spacing: 0) {
                    ForEach(sounds, id: \.self) { name in
                        SoundRow(name: name, selected: name == model.completionSound,
                                 isDefault: name == Companion.defaultSound) {
                            withAnimation(SettingsMotion.curve(reduceMotion: model.reduceMotion)) {
                                model.setCompletionSound(name)
                            }
                        }
                    }
                }
                .padding(4)
                .disabled(model.muted)
                .opacity(model.muted ? 0.5 : 1)
            }
            SettingsFooter("Plays once when a card opens. Approvals stay silent, and so do items restored after a restart. Choosing a sound plays it.")

            SettingsHeader("Completions")
            SettingsCard {
                SettingsRow(title: "Clear completions marked read in Codex", detail: model.desktopReadStateMessage) {
                    Toggle("Clear completions marked read in Codex", isOn: $model.desktopReadStateEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .onChange(of: model.desktopReadStateEnabled) { _, enabled in model.desktopReadStateChanged(enabled) }
                }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Test notification", detail: nil) {
                    HStack {
                        Button("Dismiss", action: model.dismissTest).disabled(!model.attention.pending)
                        Button("Send Test", action: model.sendTest)
                    }
                }
            }
            SettingsFooter("Steer reads Codex's own desktop read state and never marks a task read itself.")
        }
    }
}

/// One system sound: a check mark when chosen, and a play button that previews it.
private struct SoundRow: View {
    let name: String
    let selected: Bool
    let isDefault: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor).opacity(selected ? 1 : 0).frame(width: 16)
                Text(name)
                Spacer(minLength: 8)
                if isDefault { Text("Default").font(.subheadline).foregroundStyle(.secondary) }
                Button { NSSound(named: name)?.play() } label: {
                    Image(systemName: "play.fill").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Preview \(name)")
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(selected ? Color.accentColor.opacity(0.1) : .clear, in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedback())
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AboutControls: View {
    let quit: () -> Void
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }

    var body: some View {
        ControlsPage(section: .about) {
            VStack(spacing: 6) {
                Sprite(working: false, reduceMotion: true)
                    .scaleEffect(4)
                    .frame(width: 84, height: 84)
                    .background(.black, in: .rect(cornerRadius: 20, style: .continuous))
                    .accessibilityHidden(true)
                Text("Steer").font(.title2.bold()).padding(.top, 10)
                Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
                Text("One notch for every local agent session: what's working, what needs you, and a way back to it.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 340)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)

            SettingsHeader("Works with")
            SettingsCard {
                SettingsRow(title: "Agents", detail: nil) {
                    Text("Codex desktop · Codex CLI · Claude Code").foregroundStyle(.secondary)
                }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Terminals", detail: nil) {
                    Text("Ghostty · herdr").foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Quit Steer", action: quit)
                    .accessibilityHint("Stops Steer and closes its menu-bar companion.")
                Spacer()
            }
            .padding(.top, 8)
        }
    }
}

/// Strip and queue appearance for one display kind at a time. Changes apply at once and the preview
/// redraws with them; the notch uses the profile of the display it is on.
private struct NotchControls: View {
    @ObservedObject var model: Companion
    @State private var profile: DisplayProfile

    init(model: Companion) {
        self.model = model
        _profile = State(initialValue: model.activeProfile)
    }

    private var appearance: NotchAppearance { model.appearances[profile] ?? .standard }

    private func binding<Value>(_ field: WritableKeyPath<NotchAppearance, Value>) -> Binding<Value> {
        Binding(get: { appearance[keyPath: field] }, set: { value in
            var updated = appearance
            updated[keyPath: field] = value
            withAnimation(SettingsMotion.curve(reduceMotion: model.reduceMotion)) {
                model.setAppearance(updated, for: profile)
            }
        })
    }

    var body: some View {
        ControlsPage(section: .notch) {
            SlidingSegments(title: "Display being configured", selection: $profile.animation(SettingsMotion.curve(reduceMotion: model.reduceMotion)),
                            options: [(DisplayProfile.macBookNotch, "MacBook notch"), (DisplayProfile.externalDisplay, "External display")])
        } content: {
            NotchPreview(appearance: appearance, profile: profile, reduceMotion: model.reduceMotion)
                .animation(SettingsMotion.curve(reduceMotion: model.reduceMotion), value: appearance)
                .animation(SettingsMotion.curve(reduceMotion: model.reduceMotion), value: profile)

            SettingsHeader("Strip")
            SettingsCard {
                SettingsRow(title: "Left side", detail: nil) {
                    SlidingSegments(title: "Left side", selection: binding(\.leftWing),
                                    options: [(StripLeftWing.spritesAndCount, "Sprites and count"), (StripLeftWing.countOnly, "Count only"), (StripLeftWing.none, "None")])
                }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Center label", detail: nil) {
                    SlidingSegments(title: "Center label", selection: binding(\.centerLabel),
                                    options: [(StripCenterLabel.taskName, "Task name"), (StripCenterLabel.sessionName, "Session name"), (StripCenterLabel.off, "Off")])
                }
                .disabled(profile == .macBookNotch)
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Usage bars", detail: nil) {
                    SlidingSegments(title: "Usage bars", selection: binding(\.usage),
                                    options: [(UsageDisplay.compact, "Compact"), (UsageDisplay.weeklyOnly, "Weekly only"), (UsageDisplay.hidden, "Hidden")])
                }
            }
            SettingsFooter(profile == .macBookNotch
                ? "These settings apply to the MacBook notch. The camera housing covers the center, so Center label is set under External display."
                : "These settings apply to external displays. The center label widens the strip to make room for it.")

            SettingsHeader("Session state")
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("How rows show working, waiting, and done")
                    HStack(spacing: 10) {
                        ForEach(SessionIndicatorStyle.allCases, id: \.self) { style in
                            IndicatorTile(style: style, selected: appearance.indicator == style,
                                          reduceMotion: model.reduceMotion) {
                                if appearance.indicator != style { SettingsClick.play() }
                                binding(\.indicator).wrappedValue = style
                            }
                        }
                    }
                }
                .padding(.horizontal, SettingsStyle.rowInset)
                .padding(.vertical, 12)
            }
            SettingsFooter("Sprite is Steer's default. Every style steps while a session works and holds still when it is idle.")

            SettingsHeader("Session list")
            SettingsCard {
                SettingsRow(title: "Panel width", detail: nil) {
                    SlidingSegments(title: "Panel width", selection: binding(\.panelWidth),
                                    options: [(PanelWidth.standard, "Standard"), (PanelWidth.wide, "Wide"), (PanelWidth.extraWide, "Extra wide")])
                }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Sort by", detail: nil) {
                    SlidingSegments(title: "Sort by", selection: binding(\.sort),
                                    options: [(QueueSort.needsAttention, "Needs attention"), (QueueSort.lastUpdate, "Last update")])
                }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Group by", detail: nil) {
                    FormMenu(title: "Group by", selection: binding(\.grouping),
                             options: [(.none, "None"), (.state, "State"), (.agent, "Agent"), (.project, "Project")])
                }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Move completions to Earlier after", detail: nil) {
                    FormMenu(title: "Move completions to Earlier after", selection: binding(\.earlier),
                             options: [(.twoMinutes, "2 minutes"), (.fiveMinutes, "5 minutes"), (.tenMinutes, "10 minutes"),
                                       (.twentyMinutes, "20 minutes"), (.never, "Never")])
                }
            }
            SettingsFooter("Panel width sets how far the open list widens past the strip; it never runs past the display's edges. Live approvals and waiting questions always stay first. Last update orders everything else newest first. Older completions stay listed until you dismiss or open them.")
        }
    }
}

/// A small, static rendering of the strip on a desktop backdrop, drawn from the same notch views.
private struct NotchPreview: View {
    let appearance: NotchAppearance
    let profile: DisplayProfile
    let reduceMotion: Bool

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.69, green: 0.76, blue: 0.85), Color(red: 0.85, green: 0.79, blue: 0.75)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.white.opacity(0.35)).frame(height: 24)
            strip
            VStack {
                Spacer()
                Text(profile == .macBookNotch ? "Preview · MacBook notch" : "Preview · External display")
                    .font(.subheadline).foregroundStyle(.black.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(height: 112)
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the notch strip")
    }

    private var strip: some View {
        HStack(spacing: 6) {
            switch appearance.leftWing {
            case .spritesAndCount:
                Sprite(working: true, reduceMotion: reduceMotion, color: 0)
                Sprite(working: false, reduceMotion: reduceMotion, color: 1)
                Badge(count: 1)
            case .countOnly:
                Sprite(working: true, reduceMotion: reduceMotion, color: 0)
                Badge(count: 1)
            case .none:
                EmptyView()
            }
            Spacer(minLength: 12)
            if appearance.effectiveCenterLabel(on: profile) != .off {
                Text(appearance.centerLabel == .taskName ? "fix-auth-flow" : "Codex · steer")
                    .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).lineLimit(1)
                Spacer(minLength: 12)
            } else if profile == .macBookNotch {
                Color.clear.frame(width: 110, height: 1)
                Spacer(minLength: 12)
            }
            if appearance.usage != .hidden {
                RoundedRectangle(cornerRadius: 1).fill(NotchStyle.well).frame(width: 4, height: 12)
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1).fill(NotchStyle.codexUsage).frame(height: 7)
                    }
                Text("58%").font(NotchStyle.mono(10)).foregroundStyle(NotchStyle.ink)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 340, height: 28)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous))
    }
}

/// One choice in the indicator picker: two rows on black, one working and one idle.
private struct IndicatorTile: View {
    let style: SessionIndicatorStyle
    let selected: Bool
    let reduceMotion: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    sampleRow(working: true, width: 56)
                    sampleRow(working: false, width: 40)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .background(.black, in: .rect(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-4)
                        .opacity(selected ? 1 : 0)
                }
                Text(style.rawValue.capitalized).font(.callout.weight(selected ? .medium : .regular))
            }
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedback())
        .accessibilityLabel(style.rawValue.capitalized)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sampleRow(working: Bool, width: CGFloat) -> some View {
        HStack(spacing: 7) {
            if style != .tint {
                SessionMark(style: style, working: working, reduceMotion: reduceMotion, color: working ? 0 : 1)
            }
            RoundedRectangle(cornerRadius: 2).fill(working ? NotchStyle.text : NotchStyle.well).frame(width: width, height: 4)
        }
        .modifier(SessionTint(active: style == .tint && working, working: working, reduceMotion: reduceMotion, color: 0))
    }
}
