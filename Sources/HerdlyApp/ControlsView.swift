import AppKit
import SwiftUI
import HerdlyCore

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
    /// Status pill text: a darker green and orange in light mode so they read on their 12% tint.
    static let readyText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
            : NSColor(srgbRed: 0.14, green: 0.54, blue: 0.24, alpha: 1)
    })
    static let attentionText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1)
            : NSColor(srgbRed: 0.79, green: 0.2, blue: 0, alpha: 1)
    })
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
            ControlsSidebar(selection: $selection, status: "\(model.workingCount) working · \(model.currentToCheckCount) to check",
                            sprite: model.appearance.sprite)
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
    let sprite: SpriteKind

    var body: some View {
        List(selection: $selection) {
            Section("Notch") {
                ForEach([ControlSection.general, .notch, .notifications]) { section in
                    SidebarLabel(section: section, sprite: sprite).tag(section)
                }
            }
            Section("Connections") {
                ForEach([ControlSection.agents, .terminals]) { section in
                    SidebarLabel(section: section, sprite: sprite).tag(section)
                }
            }
            Section {
                SidebarLabel(section: .about, sprite: sprite).tag(ControlSection.about)
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
    /// The notch's chosen animal, so the Notch tile shows what the strip shows.
    let sprite: SpriteKind

    var body: some View {
        Label {
            Text(section.title)
        } icon: {
            Group {
                if section == .notch {
                    Sprite(kind: sprite, working: false, reduceMotion: true)
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
        case .about: AboutControls(sprite: model.appearance.sprite, quit: model.quit)
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
            }
            SettingsFooter("Keeping a card open never extends an approval. Each request still hands back to its agent 30 seconds after it arrives. Closing this window keeps Herdly running in the menu bar.")
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

/// One card per agent: name, versions and status, a ⋯ menu for setup actions, and a row for each
/// problem that applies (DESIGN.md, Settings Window, Agents pane).
private struct AgentControls: View {
    @ObservedObject var model: Companion
    @State private var preview: SetupPreview?

    /// `setupStatus` is only a default until the first detection lands, so it reads as unknown until then.
    private var summary: AgentSummary {
        AgentSummary.codex(model.setupCapabilities, status: model.setupChecked ? model.setupStatus : nil,
                           statusText: model.setupStatusText)
    }

    var body: some View {
        ControlsPage(section: .agents) {
            VStack(alignment: .leading, spacing: 28) {
                codexCard
                ClaudeAgentControls(setup: model.claude, preview: $preview)
            }
        }
        .sheet(item: $preview) { SetupPreviewSheet(preview: $0) }
    }

    private var codexCard: some View {
        let summary = summary
        return SettingsCard {
            AgentCardHeader(name: "Codex", subtitle: summary.subtitle, symbol: "terminal", tile: Color(white: 0.11),
                            status: summary.status, menuLabel: "Codex actions") {
                if model.canConfigureSetup {
                    Button("Configure Codex", action: model.configureCodex)
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            } actions: {
                Button("Review Again", action: model.refreshSetup)
                if let plan = model.setupPlan, case .ready = plan.status, plan.requiresConfigure {
                    Button("Show Setup Changes…") {
                        let hooks = String(data: plan.hooksChange, encoding: .utf8) ?? "(unreadable)"
                        preview = SetupPreview(title: "Codex setup changes",
                                               text: "config.toml\n\(plan.configChange)\n\nhooks.json\n\(hooks)\n\nhelper command\n\(plan.helperCommand)")
                    }
                }
                if model.canUndoSetup {
                    Divider()
                    Button("Undo Setup…", action: model.undoCodexSetup)
                }
            }
            AgentProblemRows(problems: summary.problems)
            AgentMessageRow(message: model.setupMessage)
        }
    }

    /// A surface's version as the row's value: the version when it is supported, otherwise why not.
    static func version(installed: Bool, supported: Bool, version: String?, minimum: String) -> String {
        guard installed else { return "Not installed" }
        guard supported else { return "\(version ?? "Unknown version") · needs \(minimum) or later" }
        return version ?? "Installed"
    }
}

/// Text shown in a sheet from a ⋯ menu: exact, monospaced setup changes or diagnostics, or a plain
/// explanation such as a terminal's How Open Works….
private struct SetupPreview: Identifiable {
    let title: String
    let text: String
    var monospaced = true
    var id: String { title }
}

private struct SetupPreviewSheet: View {
    let preview: SetupPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preview.title).font(.headline).accessibilityAddTraits(.isHeader)
            ScrollView {
                Text(preview.text)
                    .font(preview.monospaced ? .system(.caption, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(SettingsStyle.sectionFill, in: .rect(cornerRadius: 8, style: .continuous))
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: preview.monospaced ? 440 : 200)
        .onExitCommand { dismiss() }
    }
}

/// An agent's status: a green dot when connected, orange when it needs attention, gray while unknown.
private struct AgentStatusBadge: View {
    let status: AgentHeaderStatus

    var body: some View {
        switch status {
        case .connected: StatusBadge(title: status.title, color: .green)
        case .attention: StatusBadge(title: status.title, color: .orange)
        case .checking: StatusBadge(title: status.title, color: .secondary)
        }
    }
}

/// The 22pt borderless ⋯ button that opens an agent's or folder's setup actions.
private struct AgentActionsMenu<Actions: View>: View {
    let label: String
    @ViewBuilder let actions: Actions

    var body: some View {
        Menu { actions } label: {
            Image(systemName: "ellipsis").frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(label)
    }
}

/// An agent card's first row: tile, name and versions, status, a Configure button while setup is
/// needed, and the ⋯ menu of setup actions.
private struct AgentCardHeader<Configure: View, Actions: View>: View {
    let name: String
    let subtitle: String
    let symbol: String
    let tile: Color
    let status: AgentHeaderStatus
    let menuLabel: String
    @ViewBuilder let configure: Configure
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tile, in: .rect(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            AgentStatusBadge(status: status)
            configure
            AgentActionsMenu(label: menuLabel) { actions }
        }
        .padding(.horizontal, SettingsStyle.rowInset)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
    }
}

/// A value with an orange dot before it: the fix for a problem row.
private struct ProblemValue: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.orange).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A row per problem: what needs fixing on the left, an orange dot and the fix on the right.
/// `indent` sets a folder's own problems beneath its row.
private struct AgentProblemRows: View {
    let problems: [AgentProblem]
    var indent: CGFloat = 0

    var body: some View {
        ForEach(problems) { problem in
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            SettingsRow(title: problem.label, detail: nil) { ProblemValue(text: problem.value) }
                .padding(.leading, indent)
                .accessibilityElement(children: .combine)
        }
    }
}

/// The last setup action's result, kept in its agent's card while there is one, so a failure stays readable.
private struct AgentMessageRow: View {
    let message: String

    var body: some View {
        if !message.isEmpty {
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            Text(message)
                .font(.subheadline).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsStyle.rowInset).padding(.vertical, 9)
        }
    }
}

/// The Claude Code card. Its header and rows describe the default folder; each added folder is a
/// row beneath them with its own status, Configure button and ⋯ menu, and its problems indented under it.
private struct ClaudeAgentControls: View {
    @ObservedObject var setup: ClaudeSetupModel
    @Binding var preview: SetupPreview?

    var body: some View {
        SettingsCard {
            if let root = setup.roots.first {
                defaultFolder(root)
            } else {
                // No folder to describe yet: keep the card's header so adding a folder stays reachable.
                header(AgentSummary.claudeWithoutFolders(checked: setup.checked), menuLabel: "Claude Code actions") {
                    EmptyView()
                } actions: {
                    Button("Add Another Claude Folder…", action: setup.addAlternateRoot)
                }
            }
            ForEach(Array(setup.roots.dropFirst())) { root in addedFolder(root) }
            AgentMessageRow(message: setup.message)
        }
    }

    private func readyPlan(_ root: ClaudeSetupModel.Root) -> ClaudeSetupPlan? {
        guard let plan = root.plan, case .ready = plan.status else { return nil }
        return plan
    }

    private func summary(_ root: ClaudeSetupModel.Root) -> AgentSummary {
        AgentSummary.claude(checked: setup.checked, root.capabilities, displayPath: root.displayPath, status: root.status,
                            statusText: ClaudeSetupModel.statusText(root.status),
                            addsHooks: readyPlan(root)?.addsHooks ?? false)
    }

    private func usage(_ root: ClaudeSetupModel.Root) -> AgentUsage? {
        guard setup.usageEnabled(for: root) else { return nil }
        return AgentSummary.claudeUsage(root.usage, status: root.usageStatus, now: Date().timeIntervalSince1970)
    }

    private func actionsLabel(_ root: ClaudeSetupModel.Root) -> String {
        "Claude Code actions for \(root.displayPath)"
    }

    private func offersUndo(_ root: ClaudeSetupModel.Root) -> Bool {
        root.status.offersUndo(planReady: readyPlan(root) != nil)
    }

    private func header<Configure: View, Actions: View>(
        _ summary: AgentSummary, menuLabel: String,
        @ViewBuilder configure: () -> Configure, @ViewBuilder actions: () -> Actions
    ) -> some View {
        AgentCardHeader(name: "Claude Code", subtitle: summary.subtitle, symbol: "sparkle",
                        tile: Color(red: 0.851, green: 0.467, blue: 0.341), status: summary.status,
                        menuLabel: menuLabel, configure: configure, actions: actions)
    }

    @ViewBuilder
    private func defaultFolder(_ root: ClaudeSetupModel.Root) -> some View {
        let summary = summary(root)
        let plan = readyPlan(root)
        header(summary, menuLabel: actionsLabel(root)) {
            configureButton(root)
        } actions: {
            reviewActions(root)
            Button("Add Another Claude Folder…", action: setup.addAlternateRoot)
            if offersUndo(root) {
                Divider()
                undoButton(root)
            }
        }
        AgentProblemRows(problems: summary.problems)
        if plan != nil {
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            SettingsRow(title: "Usage limits on the strip", detail: nil) {
                HStack(spacing: 10) {
                    switch usage(root) {
                    case .reading(let text)?: Text(text).foregroundStyle(.secondary)
                    case .unavailable?: Text("Unavailable").foregroundStyle(.secondary)
                    case .problem(let reason)?: ProblemValue(text: reason)
                    case nil: EmptyView()
                    }
                    usageToggle(root).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            SettingsRow(title: "Name sessions with Haiku", detail: nil) {
                titlesToggle(root).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private func addedFolder(_ root: ClaudeSetupModel.Root) -> some View {
        let summary = summary(root)
        let plan = readyPlan(root)
        Divider().padding(.horizontal, SettingsStyle.rowInset)
        HStack(spacing: 10) {
            Text(root.displayPath)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .accessibilityLabel("Claude folder \(root.displayPath)")
            Spacer(minLength: 8)
            AgentStatusBadge(status: summary.status)
            configureButton(root)
            AgentActionsMenu(label: actionsLabel(root)) {
                reviewActions(root)
                if plan != nil {
                    usageToggle(root)
                    titlesToggle(root)
                }
                Divider()
                if offersUndo(root) { undoButton(root) }
                Button("Remove Folder", role: .destructive) { setup.removeAlternateRoot(root) }
                    .accessibilityLabel("Remove Claude folder \(root.displayPath)")
            }
        }
        .padding(.horizontal, SettingsStyle.rowInset)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        AgentProblemRows(problems: summary.problems + [usage(root)?.problem].compactMap { $0 }, indent: 16)
    }

    @ViewBuilder
    private func configureButton(_ root: ClaudeSetupModel.Root) -> some View {
        if let plan = readyPlan(root),
           root.status.offersConfigure(requiresConfigure: plan.requiresConfigure,
                                       usageMatches: root.usageInstalled == setup.usageEnabled(for: root)) {
            Button("Configure Claude") { setup.configure(root) }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .accessibilityLabel("Configure Claude for \(root.displayPath)")
        }
    }

    /// Review Again and Show Setup Changes…, offered only while the folder's plan is ready, as before.
    @ViewBuilder
    private func reviewActions(_ root: ClaudeSetupModel.Root) -> some View {
        if let plan = readyPlan(root) {
            Button("Review Again", action: setup.refresh)
                .accessibilityLabel("Review Claude setup for \(root.displayPath)")
            Button("Show Setup Changes…") {
                preview = SetupPreview(title: "Claude Code setup changes for \(root.displayPath)",
                                       text: previewText(root, plan: plan))
            }
            .accessibilityLabel("Show Claude setup changes for \(root.displayPath)")
        }
    }

    private func undoButton(_ root: ClaudeSetupModel.Root) -> some View {
        Button("Undo Setup…") { setup.undo(root) }
            .accessibilityLabel("Undo Claude setup for \(root.displayPath)")
    }

    /// Plain toggles so they read as checkmark items in a folder's menu; rows style them as mini switches.
    private func usageToggle(_ root: ClaudeSetupModel.Root) -> some View {
        Toggle("Usage limits on the strip", isOn: Binding(
            get: { setup.usageEnabled(for: root) },
            set: { setup.setUsageEnabled($0, for: root) }
        ))
        .accessibilityLabel("Claude usage limits on the strip for \(root.displayPath)")
    }

    private func titlesToggle(_ root: ClaudeSetupModel.Root) -> some View {
        Toggle("Name sessions with Haiku", isOn: Binding(
            get: { setup.sessionTitlesEnabled(for: root) },
            set: { setup.setSessionTitlesEnabled($0, for: root) }
        ))
        .accessibilityLabel("Name Claude sessions with Haiku for \(root.displayPath)")
    }

    private func previewText(_ root: ClaudeSetupModel.Root, plan: ClaudeSetupPlan) -> String {
        let hookFields = plan.ownedHooks.map { hook in
            "  hooks.\(hook.event) matcher=\(hook.matcher ?? "<any>") command=\(hook.command) timeout=\(ClaudeSetupRequirements.hookTimeout)"
        }.joined(separator: "\n")
        let environmentFields = plan.ownedEnvironment.isEmpty
            ? "  env.\(ClaudeSetupRequirements.titleDisableEnvironmentKey)=\(ClaudeSetupRequirements.titleDisableEnvironmentValue) (already present; preserved)"
            : plan.ownedEnvironment.map { key, value in
                "  env.\(key)=\(value) (Herdly adds and owns)"
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
}

/// Settings › Terminals: one card per section, one row per shown host (product.md, "Agreed terminal
/// host presentation"; #317). Each row's ⋯ menu opens its diagnostics or its How Open Works text in a sheet.
private struct TerminalControls: View {
    @ObservedObject var model: Companion
    @State private var sheet: SetupPreview?

    var body: some View {
        ControlsPage(section: .terminals) {
            SettingsHeader("Terminals")
            section(TerminalHost.terminals)
            SettingsHeader("Multiplexers")
            section(TerminalHost.multiplexers)
        }
        .sheet(item: $sheet) { SetupPreviewSheet(preview: $0) }
    }

    /// The section's card, with an inset divider between hosts. Each host's acceptance ticket turns on
    /// `showsCard` to add its row here.
    @ViewBuilder
    private func section(_ hosts: [TerminalHost]) -> some View {
        let shown = hosts.filter(\.showsCard)
        if !shown.isEmpty {
            SettingsCard {
                ForEach(shown, id: \.self) { host in
                    VStack(spacing: 0) {
                        if host != shown.first { Divider().padding(.horizontal, SettingsStyle.rowInset) }
                        row(host)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ host: TerminalHost) -> some View {
        switch host {
        case .ghostty: GhosttyHostRow(model: model, sheet: $sheet)
        case .herdr: HerdrHostRow(model: model, sheet: $sheet)
        case .iTerm2: ITerm2HostRow(model: model, state: model.iTerm2, sheet: $sheet)
        case .terminalApp: TerminalAppHostRow(model: model, sheet: $sheet)
        case .wezTerm: WezTermHostRow(model: model, state: model.wezTerm, sheet: $sheet)
        case .tmux: TmuxHostRow(model: model, state: model.tmux, sheet: $sheet)
        case .zellij: ZellijHostRow(model: model, state: model.zellij, sheet: $sheet)
        }
    }
}

/// A host's row: name and dim version, status badge, switch and ⋯ menu, with a `line` per problem
/// beneath it and no divider between them. `diagnostics` is nil when there is nothing to show, which
/// disables Show Diagnostics….
private struct TerminalHostRow<Switch: View, Problem: Hashable, Line: View>: View {
    let host: TerminalHost
    let version: String?
    let badge: HerdrReadinessBadge?
    let diagnostics: String?
    let problems: [Problem]
    @Binding var sheet: SetupPreview?
    @ViewBuilder let toggle: Switch
    @ViewBuilder let line: (Problem) -> Line

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(host.displayName).font(.system(size: 13))
                    if let version {
                        Text(version).font(.system(size: 11)).foregroundStyle(.primary.opacity(0.4))
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                HostStatusBadge(host: host, badge: badge)
                toggle
                AgentActionsMenu(label: "\(host.displayName) actions") {
                    Button("Show Diagnostics…") {
                        if let diagnostics { sheet = SetupPreview(title: "\(host.displayName) diagnostics", text: diagnostics) }
                    }
                    .disabled(diagnostics == nil)
                    Button("How Open Works…") {
                        sheet = SetupPreview(title: "How Open works in \(host.displayName)", text: host.howOpenWorks,
                                             monospaced: false)
                    }
                }
            }
            .padding(.horizontal, SettingsStyle.rowInset)
            .frame(minHeight: 38)
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 6) { ForEach(problems, id: \.self, content: line) }
                    .padding(.horizontal, SettingsStyle.rowInset)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The exact diagnostics text for Show Diagnostics…, nil when hidden or empty.
private func diagnosticsText(_ lines: [String], shown: Bool = true) -> String? {
    shown && !lines.isEmpty ? lines.joined(separator: "\n") : nil
}

private extension Companion {
    /// A Settings binding to the switch of a host without Automation access (`setHostSwitch`).
    func hostSwitchBinding(_ host: TerminalHost) -> Binding<Bool> {
        Binding(get: { self.hostSwitches.isOn(host) }, set: { self.setHostSwitch(host, on: $0) })
    }
}

/// The host's switch as a mini switch; `label` is its VoiceOver name.
private struct HostSwitch: View {
    let label: String
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(label, isOn: isOn)
            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            .accessibilityLabel(label)
    }
}

/// A tinted status pill: green Ready, orange Needs attention, gray Not in use or Off, and a small
/// spinner while herdr's first scan runs.
private struct HostStatusBadge: View {
    let host: TerminalHost
    let badge: HerdrReadinessBadge?

    var body: some View {
        if let badge {
            Text(badge.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(foreground(badge))
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(fill(badge), in: .rect(cornerRadius: 5, style: .continuous))
                .accessibilityLabel("Status: \(badge.title)")
        } else {
            ProgressView().controlSize(.small).accessibilityLabel("Checking \(host.displayName)")
        }
    }

    private func foreground(_ badge: HerdrReadinessBadge) -> Color {
        switch badge {
        case .ready: SettingsStyle.readyText
        case .needsAttention: SettingsStyle.attentionText
        case .off, .notInUse: .secondary
        }
    }

    private func fill(_ badge: HerdrReadinessBadge) -> Color {
        switch badge {
        case .ready: Color.green.opacity(0.12)
        case .needsAttention: Color.orange.opacity(0.12)
        case .off, .notInUse: Color.primary.opacity(0.06)
        }
    }
}

/// One problem under a row or in a card: 12pt text after an orange dot, with an optional fix at its
/// trailing edge.
private struct CardProblemLine<Fix: View>: View {
    let text: String
    @ViewBuilder let fix: Fix

    init(_ text: String, @ViewBuilder fix: () -> Fix = { EmptyView() }) {
        self.text = text
        self.fix = fix()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(.orange).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            fix
        }
    }
}

/// Open Settings… for a denied Automation permission: opens Privacy & Security › Automation.
private struct OpenAutomationSettingsButton: View {
    var body: some View {
        Button("Open Settings…", action: GhosttyAutomationPermission.openSettings)
            .controlSize(.small)
    }
}

private struct GhosttyHostRow: View {
    @ObservedObject var model: Companion
    @Binding var sheet: SetupPreview?

    var body: some View {
        let capabilities = model.setupCapabilities
        let row = GhosttyPresentation.settingsRow(on: model.ghosttyEnabled, installed: capabilities.ghosttyInstalled,
                                                  supported: capabilities.ghostty,
                                                  minimum: CodexSetupRequirements.minimumGhosttyVersion,
                                                  access: model.ghosttyAccess,
                                                  permissionVerified: model.ghosttyPermissionVerified)
        TerminalHostRow(host: .ghostty,
                        version: AgentControls.version(installed: capabilities.ghosttyInstalled,
                                                       supported: capabilities.ghostty,
                                                       version: capabilities.ghosttyVersion,
                                                       minimum: CodexSetupRequirements.minimumGhosttyVersion),
                        badge: row.badge, diagnostics: nil, problems: row.problems, sheet: $sheet) {
            HostSwitch(label: "Enable Ghostty", isOn: $model.ghosttyEnabled)
                .onChange(of: model.ghosttyEnabled) { _, enabled in model.ghosttyChanged(enabled) }
        } line: { problem in
            CardProblemLine(problem.message) {
                if problem.opensAutomationSettings { OpenAutomationSettingsButton() }
            }
        }
    }
}

/// Terminal.app (#239), shown since its acceptance (#244). A denied Automation permission offers
/// Open Settings… on its line.
private struct TerminalAppHostRow: View {
    @ObservedObject var model: Companion
    @Binding var sheet: SetupPreview?

    var body: some View {
        let row = model.terminalAppSettingsRow
        TerminalHostRow(host: .terminalApp, version: model.terminalApp.version ?? "Not installed",
                        badge: row.badge.readiness, diagnostics: diagnosticsText(model.terminalApp.diagnostics),
                        problems: row.problems, sheet: $sheet) {
            HostSwitch(label: "Enable Terminal.app", isOn: model.hostSwitchBinding(.terminalApp))
        } line: { problem in
            CardProblemLine(problem.message) {
                if problem.opensAutomationSettings { OpenAutomationSettingsButton() }
            }
        }
    }
}

/// WezTerm (#240), shown since its acceptance (#245). It needs no Automation access.
private struct WezTermHostRow: View {
    @ObservedObject var model: Companion
    @ObservedObject var state: WezTermState
    @Binding var sheet: SetupPreview?

    var body: some View {
        let row = model.wezTermSettingsRow
        let on = model.hostSwitches.isOn(.wezTerm)
        TerminalHostRow(host: .wezTerm, version: state.installed ? state.version ?? "Unknown" : "Not installed",
                        badge: row.badge,
                        diagnostics: diagnosticsText(state.diagnostics, shown: on),
                        problems: row.problems, sheet: $sheet) {
            HostSwitch(label: "Enable WezTerm", isOn: model.hostSwitchBinding(.wezTerm))
        } line: { CardProblemLine($0.message) }
    }
}

/// tmux (#241). Shown only once its acceptance (#246) turns on `TerminalHost.tmux.showsCard`.
private struct TmuxHostRow: View {
    @ObservedObject var model: Companion
    @ObservedObject var state: TmuxState
    @Binding var sheet: SetupPreview?

    var body: some View {
        let row = model.tmuxSettingsRow
        let on = model.hostSwitches.isOn(.tmux)
        TerminalHostRow(host: .tmux, version: nil, badge: row.badge.readiness,
                        diagnostics: diagnosticsText(state.diagnostics, shown: on),
                        problems: row.problems, sheet: $sheet) {
            HostSwitch(label: "Enable tmux", isOn: model.hostSwitchBinding(.tmux))
        } line: { CardProblemLine($0) }
    }
}

/// Zellij (#242). Shown only once its acceptance (#247) turns on `TerminalHost.zellij.showsCard`.
private struct ZellijHostRow: View {
    @ObservedObject var model: Companion
    @ObservedObject var state: ZellijState
    @Binding var sheet: SetupPreview?

    var body: some View {
        let row = model.zellijSettingsRow
        let on = model.hostSwitches.isOn(.zellij)
        TerminalHostRow(host: .zellij, version: nil, badge: row.badge.readiness,
                        diagnostics: diagnosticsText(state.diagnostics, shown: on),
                        problems: row.problems, sheet: $sheet) {
            HostSwitch(label: "Enable Zellij", isOn: model.hostSwitchBinding(.zellij))
        } line: { CardProblemLine($0) }
    }
}

/// herdr's row. Its switch is herdr's own; Herdly contacts herdr only while it and a terminal are on.
/// Copy places a command on the pasteboard and never runs it. Exact internal reasons appear only in
/// its diagnostics, never on a notch card.
private struct HerdrHostRow: View {
    @ObservedObject var model: Companion
    @Binding var sheet: SetupPreview?
    @ObservedObject private var tty = GhosttyTTYSupportMonitor.shared

    var body: some View {
        let row = HerdrPresentation.settingsRow(switches: model.hostSwitches, inUse: model.herdr.inUse,
                                                outcome: model.herdrScanOutcome, agentsSeen: model.herdrAgentsSeen,
                                                ttySupport: tty.support)
        TerminalHostRow(host: .herdr, version: nil, badge: row.badge,
                        diagnostics: model.herdr.inUse ? diagnosticsText(diagnostics) : nil,
                        problems: row.problems, sheet: $sheet) {
            HostSwitch(label: "Enable herdr", isOn: model.hostSwitchBinding(.herdr))
        } line: { HerdrProblemLine(problem: $0) }
        .onAppear { tty.refreshIfStale() }
        .onChange(of: model.herdrScanOutcome) { _, _ in tty.refreshIfStale() }
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

/// iTerm2 (#238), shown since its acceptance (#243). Its switch asks macOS for Automation access as
/// Ghostty's does.
private struct ITerm2HostRow: View {
    @ObservedObject var model: Companion
    @ObservedObject var state: ITerm2State
    @Binding var sheet: SetupPreview?

    var body: some View {
        let on = model.hostSwitches.isOn(.iTerm2)
        let row = ITerm2Presentation.settingsRow(on: on, installed: state.installed, access: state.access,
                                                 scan: state.scan, inUse: state.inUse)
        TerminalHostRow(host: .iTerm2, version: state.installed ? (state.version ?? "Installed") : "Not installed",
                        badge: row.badge, diagnostics: diagnosticsText(diagnostics, shown: on), problems: row.problems, sheet: $sheet) {
            HostSwitch(label: "Enable iTerm2", isOn: model.hostSwitchBinding(.iTerm2))
        } line: { problem in
            CardProblemLine(problem.message) {
                if problem == .automationDenied { OpenAutomationSettingsButton() }
            }
        }
    }

    /// The scan's result and each session's latest Open in iTerm2 with its exact reason. Typed input is
    /// always unavailable there (ADR 0017).
    private var diagnostics: [String] {
        var lines = ["scan: \(state.scan)", "typed input: none (ADR 0017)"]
        for (session, line) in state.lastOpen.sorted(by: { $0.key < $1.key }) {
            lines.append("\(session.prefix(8)): \(line)")
        }
        return lines
    }
}

private extension TerminalAppSettingsRow.Badge {
    /// The same four states as every other host's badge.
    var readiness: HerdrReadinessBadge {
        switch self {
        case .off: .off
        case .notInUse: .notInUse
        case .ready: .ready
        case .needsAttention: .needsAttention
        }
    }
}

/// A herdr problem: the fix, and for an integration the exact command in monospace with Copy.
private struct HerdrProblemLine: View {
    let problem: HerdrSettingsProblem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardProblemLine(problem.message)
            if let command = problem.command {
                HStack(spacing: 12) {
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(.quaternary, in: .rect(cornerRadius: 6, style: .continuous))
                    Spacer(minLength: 8)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Copy \(command)")
                    .accessibilityHint("Copies the command. Herdly does not run it.")
                }
                .padding(.leading, 12)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Settings › Notifications (#317): the sound switch and tiles, the read-state switch, and the test
/// notification buttons. No footers.
private struct NotificationControls: View {
    @ObservedObject var model: Companion
    private let sounds = Companion.systemSoundNames
    private let soundColumns = [GridItem(.adaptive(minimum: 120, maximum: 120), spacing: 6, alignment: .leading)]

    var body: some View {
        ControlsPage(section: .notifications) {
            SettingsHeader("Sound")
            SettingsCard {
                SettingsRow(title: "Completions and questions", detail: nil) {
                    Toggle("Play a sound for new completions and questions",
                           isOn: Binding(get: { !model.muted }, set: { enabled in
                               withAnimation(SettingsMotion.curve(reduceMotion: model.reduceMotion)) { model.setSoundEnabled(enabled) }
                           }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .accessibilityLabel("Play a sound for new completions and questions")
                }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                LazyVGrid(columns: soundColumns, alignment: .leading, spacing: 6) {
                    ForEach(sounds, id: \.self) { name in
                        SoundTile(name: name, selected: name == model.completionSound) {
                            withAnimation(SettingsMotion.curve(reduceMotion: model.reduceMotion)) {
                                model.setCompletionSound(name)
                            }
                        }
                    }
                }
                .padding(10)
                .disabled(model.muted)
                .opacity(model.muted ? 0.5 : 1)
            }

            SettingsHeader("Completions")
            SettingsCard {
                SettingsRow(title: "Clear when read in Codex", detail: nil) {
                    Toggle("Clear completions marked read in Codex", isOn: $model.desktopReadStateEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .accessibilityLabel("Clear completions marked read in Codex")
                        .onChange(of: model.desktopReadStateEnabled) { _, enabled in model.desktopReadStateChanged(enabled) }
                }
                .help(model.desktopReadStateMessage)
                if model.desktopReadStateEnabled, let problem = model.desktopReadState.problemLine {
                    CardProblemLine(problem)
                        .padding(.horizontal, SettingsStyle.rowInset)
                        .padding(.bottom, 10)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                if model.attention.pending {
                    Button("Dismiss", action: model.dismissTest)
                        .accessibilityLabel("Dismiss test notification")
                }
                Button("Send Test Notification", action: model.sendTest)
            }
            .padding(.top, 6)
        }
    }
}

/// One system sound as a 120x28pt tile: the accent fill and white medium text when chosen. Choosing
/// it plays it once.
private struct SoundTile: View {
    let name: String
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            Text(name)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .frame(width: 120, height: 28)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.04),
                            in: .rect(cornerRadius: 7, style: .continuous))
                .contentShape(.rect(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(PressFeedback())
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AboutControls: View {
    let sprite: SpriteKind
    let quit: () -> Void
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }

    var body: some View {
        ControlsPage(section: .about) {
            VStack(spacing: 6) {
                Sprite(kind: sprite, working: false, reduceMotion: true)
                    .scaleEffect(4)
                    .frame(width: 84, height: 84)
                    .background(.black, in: .rect(cornerRadius: 20, style: .continuous))
                    .accessibilityHidden(true)
                Text("Herdly").font(.title2.bold()).padding(.top, 10)
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
                Button("Quit Herdly", action: quit)
                    .accessibilityHint("Stops Herdly and closes its menu-bar companion.")
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

            SettingsHeader("Sprite")
            SettingsCard {
                HStack(spacing: 10) {
                    ForEach(SpriteKind.allCases) { kind in
                        SpriteTile(kind: kind, selected: appearance.sprite == kind) {
                            if appearance.sprite != kind { SettingsClick.play() }
                            binding(\.sprite).wrappedValue = kind
                        }
                    }
                }
                .padding(.horizontal, SettingsStyle.rowInset)
                .padding(.vertical, 12)
            }

            SettingsHeader("Session list")
            SettingsCard {
                SettingsRow(title: "Panel width", detail: nil) {
                    SlidingSegments(title: "Panel width", selection: binding(\.panelWidth),
                                    options: [(PanelWidth.standard, "Standard"), (PanelWidth.wide, "Wide"), (PanelWidth.extraWide, "Extra wide")])
                }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Sort by", detail: nil) {
                    SlidingSegments(title: "Sort by", selection: binding(\.sort),
                                    options: [(QueueSort.needsAttention, "By need"), (QueueSort.lastUpdate, "Newest first")])
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
            SettingsFooter("Panel width sets how far the open list widens past the strip; it never runs past the display's edges. Live approvals always stay first, soonest deadline first, then waiting questions. Newest first orders everything else by its latest update. Older completions stay listed until you dismiss or open them.")
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
                Sprite(kind: appearance.sprite, working: true, reduceMotion: reduceMotion, color: 0)
                Sprite(kind: appearance.sprite, working: false, reduceMotion: reduceMotion, color: 1)
                Badge(count: 1)
            case .countOnly:
                Sprite(kind: appearance.sprite, working: true, reduceMotion: reduceMotion, color: 0)
                Badge(count: 1)
            case .none:
                EmptyView()
            }
            Spacer(minLength: 12)
            if appearance.effectiveCenterLabel(on: profile) != .off {
                Text(appearance.centerLabel == .taskName ? "fix-auth-flow" : "Codex · herdly")
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

/// One choice in the sprite picker: the kind's idle frame at three times the notch's cell size,
/// centred on a black well in the first session color, with its name below.
private struct SpriteTile: View {
    let kind: SpriteKind
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                // Idle, so the tile never steps or breathes; Reduce Motion has nothing to change.
                Sprite(kind: kind, working: false, reduceMotion: true, color: 0, cellSize: 6)
                    .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76)
                    .background(.black, in: .rect(cornerRadius: 9, style: .continuous))
                    .overlay {
                        // A 2pt accent ring 2pt outside the well, concentric with its 9pt corners.
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(-4)
                            .opacity(selected ? 1 : 0)
                    }
                Text(kind.name).font(.system(size: 12, weight: selected ? .medium : .regular))
            }
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedback())
        .accessibilityLabel(kind.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
