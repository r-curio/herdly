import AppKit
import SwiftUI
import HerdlyCore

private enum ControlSection: String, CaseIterable, Identifiable {
    case general
    case notifications
    case agents
    case terminals
    case about

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .agents: "sparkles"
        case .terminals: "apple.terminal.fill"
        case .notifications: "bell.fill"
        case .about: "info.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .general: .gray
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
    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
    static func dynamic(dark: CGFloat, light: CGFloat) -> NSColor {
        dynamic(dark: NSColor(white: dark, alpha: 1), light: NSColor(white: light, alpha: 1))
    }
    static let windowBackground = dynamic(dark: 0.075, light: 1)
    static let pageBackground = Color(nsColor: windowBackground)
    static let sectionFill = Color(nsColor: dynamic(dark: 0.125, light: 0.976))
    static let sidebarFill = Color(nsColor: dynamic(dark: 0.11, light: 0.93))
    static let rowInset: CGFloat = 10
    /// Status pill text: a darker green and orange in light mode so they read on their 12% tint.
    static let readyText = Color(nsColor: dynamic(dark: NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1),
                                                  light: NSColor(srgbRed: 0.14, green: 0.54, blue: 0.24, alpha: 1)))
    static let attentionText = Color(nsColor: dynamic(dark: NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1),
                                                      light: NSColor(srgbRed: 0.79, green: 0.2, blue: 0, alpha: 1)))
    /// Status pill fills: a 12% green or orange tint, or a 6% neutral one for Off and Not in use.
    static let readyFill = Color.green.opacity(0.12)
    static let attentionFill = Color.orange.opacity(0.12)
    static let quietFill = Color.primary.opacity(0.06)
    /// The symbol tiles agents fall back to without their app's icon (DESIGN.md, Agents pane).
    static let codexTile = Color(white: 0.11)
    static let claudeTile = Color(red: 0.851, green: 0.467, blue: 0.341)
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
        let stored = UserDefaults.standard.string(forKey: "controlsSection")
        // The Notch pane merged into General (#466). A window last left on Notch saved "notch", which
        // no longer names a section, so map it to General rather than fall through to the fresh-install choice.
        let saved = stored == "notch" ? .general : stored.flatMap(ControlSection.init(rawValue:))
        _selection = State(initialValue: saved ?? (model.canUndoSetup ? .general : .agents))
    }

    var body: some View {
        // A fixed sidebar panel that runs the full window height, so the window buttons sit inside
        // it as in System Settings and Raycast. It never collapses.
        HStack(spacing: 0) {
            ControlsSidebar(selection: $selection)
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

    var body: some View {
        List(selection: $selection) {
            Section("Notch") {
                ForEach([ControlSection.general, .notifications]) { section in
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
            Image(systemName: section.symbol).font(.system(size: 11, weight: .semibold))
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
        case .agents: AgentControls(model: model)
        case .terminals: TerminalControls(model: model)
        case .notifications: NotificationControls(model: model)
        case .about: AboutControls(quit: model.quit, sendFeedback: model.showFeedback)
        }
    }
}

/// A pane: its title row sits in the window's title bar beside the traffic lights, with an optional
/// control at its trailing edge, and the grouped sections scroll beneath it. An optional footer stays
/// pinned below the scrolling sections.
private struct ControlsPage<Accessory: View, Content: View, Footer: View>: View {
    let section: ControlSection
    let accessory: Accessory
    let content: Content
    let footer: Footer

    init(section: ControlSection, @ViewBuilder content: () -> Content) where Accessory == EmptyView, Footer == EmptyView {
        self.section = section
        self.accessory = EmptyView()
        self.content = content()
        self.footer = EmptyView()
    }

    init(section: ControlSection, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content)
    where Footer == EmptyView {
        self.section = section
        self.accessory = accessory()
        self.content = content()
        self.footer = EmptyView()
    }

    init(section: ControlSection, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer)
    where Accessory == EmptyView {
        self.section = section
        self.accessory = EmptyView()
        self.content = content()
        self.footer = footer()
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
            // Scrolled content stops at the title row. Without this, on macOS 26 it shows through
            // behind the title and the window buttons.
            .clipped()
            footer
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
/// `dividerBefore` draws a menu separator above that option.
private struct FormMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var dividerBefore: Value? = nil

    private var current: String { options.first { $0.value == selection }?.label ?? "" }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.value) { option in
                    if option.value == dividerBefore { Divider() }
                    Text(option.label).tag(option.value)
                }
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

/// A section header (13pt bold) aligned with the row text, with room above it for the previous section.
/// An optional note sits right-aligned on the same line in 12pt secondary text.
private struct SettingsHeader: View {
    let title: String
    let note: String?
    init(_ title: String, note: String? = nil) {
        self.title = title
        self.note = note
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let note {
                Spacer(minLength: 12)
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, SettingsStyle.rowInset)
        .padding(.top, 18)
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

/// Settings › Agents (#481, Paper "Agents tab like Terminals", A1–A9): one card with a row per agent,
/// Codex then Claude Code and each added Claude folder, laid out like a Terminals host row. The rules
/// for each row's badge, switch and lines live in `AgentSettingsRow`.
private struct AgentControls: View {
    @ObservedObject var model: Companion
    @State private var preview: SetupPreview?

    var body: some View {
        ControlsPage(section: .agents) {
            SettingsCard {
                CodexAgentRow(model: model, sheet: $preview)
                ClaudeAgentRows(setup: model.claude, sheet: $preview, updates: model.agentUpdates,
                                perform: model.performAgentRowAction)
            }
            // GitHub is an optional tool, not an agent Herdly watches, so it sits under its own header
            // with the page's usual header spacing.
            SettingsHeader("Tools", note: "Optional · adds detail to finished rows")
            GitHubAgentControls(workStatus: model.workStatus)
        }
        .sheet(item: $preview) { SetupPreviewSheet(preview: $0) }
    }
}


/// Text shown in a sheet from a ⋯ menu: exact, monospaced setup changes or diagnostics, or a plain
/// explanation such as a terminal's How Open Works….
struct SetupPreview: Identifiable {
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
        case .unavailable: StatusBadge(title: status.title, color: .secondary)
        case .checking: StatusBadge(title: status.title, color: .secondary)
        }
    }
}

/// The 22pt borderless ⋯ button that opens an agent's or folder's setup actions.
struct AgentActionsMenu<Actions: View>: View {
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

/// A card's first row (the GitHub card): tile, name and an optional subtitle, status, an optional
/// button, and the ⋯ menu of actions.
private struct AgentCardHeader<Configure: View, Actions: View>: View {
    let name: String
    let subtitle: String?
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
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
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

/// The GitHub card (#417, Paper "GitHub status in Agents", 01–03): the GitHub CLI's presence and
/// sign-in, and the "Pull request status on finished rows" switch while it is signed in. Signed out
/// and not installed show the command to run with Copy; Herdly never runs either.
private struct GitHubAgentControls: View {
    @ObservedObject var workStatus: WorkStatusModel

    var body: some View {
        let cli = workStatus.cli
        SettingsCard {
            // No subtitle (#481, A9): the card's status and rows say what it needs.
            AgentCardHeader(name: "GitHub", subtitle: nil, symbol: "arrow.triangle.branch",
                            tile: Color(red: 0.14, green: 0.16, blue: 0.18), status: cli.header,
                            menuLabel: "GitHub actions") {
                EmptyView()
            } actions: {
                // With the switch off no `gh` runs, so there is nothing to check again.
                Button("Check Again") { workStatus.refreshCLI() }
                    .disabled(!workStatus.mayCheckCLI)
            }
            if workStatus.showsSwitch {
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Pull request status on finished rows", detail: nil) {
                    switchToggle.labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }
            switch cli {
            case .checking, .signedIn, .unknown:
                EmptyView()
            case .signedOut:
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                GitHubCommandRow(text: "Sign in from a terminal, then finished rows show pull requests",
                                 dot: .orange, command: "gh auth login")
            case .notInstalled:
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                GitHubCommandRow(text: "Optional. Install it to see pull requests on finished rows",
                                 dot: .secondary, command: "brew install gh")
            }
        }
        .onAppear { workStatus.refreshCLI() }
    }

    private var switchToggle: some View {
        Toggle("Pull request status on finished rows", isOn: Binding(
            get: { workStatus.isEnabled },
            set: { workStatus.setEnabled($0) }
        ))
    }
}

/// "GitHub CLI" with a dot and what to do on the right, then the command in monospace with Copy.
private struct GitHubCommandRow: View {
    let text: String
    let dot: Color
    let command: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("GitHub CLI")
                Spacer(minLength: 16)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(text).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .controlSize(.small)
                .accessibilityLabel("Copy \(command)")
                .accessibilityHint("Copies the command. Herdly does not run it.")
            }
        }
        .padding(.horizontal, SettingsStyle.rowInset)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
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
        case .rex: RexHostRow(model: model, state: model.rex, sheet: $sheet)
        case .herdrApp: HerdrAppHostRow(model: model, state: model.herdrApp, sheet: $sheet)
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
struct HostSwitch: View {
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
            StatusPill(title: badge.title, foreground: foreground(badge), fill: fill(badge))
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
        case .ready: SettingsStyle.readyFill
        case .needsAttention: SettingsStyle.attentionFill
        case .off, .notInUse: SettingsStyle.quietFill
        }
    }
}

/// A status badge's tinted pill: 11pt medium text, 5pt continuous corners.
struct StatusPill: View {
    let title: String
    let foreground: Color
    let fill: Color

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(fill, in: .rect(cornerRadius: 5, style: .continuous))
            .accessibilityLabel("Status: \(title)")
    }
}

/// One problem under a row or in a card: 12pt text after a dot (orange unless given), with an
/// optional fix at its trailing edge.
struct CardProblemLine<Fix: View>: View {
    let text: String
    let dot: Color
    @ViewBuilder let fix: Fix

    init(_ text: String, dot: Color = .orange, @ViewBuilder fix: () -> Fix = { EmptyView() }) {
        self.text = text
        self.dot = dot
        self.fix = fix()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(dot).frame(width: 6, height: 6).accessibilityHidden(true)
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
                        version: AgentDiagnostics.surfaceVersion(installed: capabilities.ghosttyInstalled,
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

/// Rex. It needs no Automation access: Herdly talks to Rex's own server socket.
private struct RexHostRow: View {
    @ObservedObject var model: Companion
    @ObservedObject var state: RexState
    @Binding var sheet: SetupPreview?

    var body: some View {
        let row = model.rexSettingsRow
        let on = model.hostSwitches.isOn(.rex)
        TerminalHostRow(host: .rex, version: state.installed ? state.version ?? "Unknown" : "Not installed",
                        badge: row.badge,
                        diagnostics: diagnosticsText(state.diagnostics, shown: on),
                        problems: row.problems, sheet: $sheet) {
            HostSwitch(label: "Enable Rex", isOn: model.hostSwitchBinding(.rex))
        } line: { CardProblemLine($0.message) }
    }
}

/// The Herdr app. It needs no Automation access: Herdly talks to herdr-core's socket and Herdr's own
/// command line.
private struct HerdrAppHostRow: View {
    @ObservedObject var model: Companion
    @ObservedObject var state: HerdrAppState
    @Binding var sheet: SetupPreview?

    var body: some View {
        let row = model.herdrAppSettingsRow
        let on = model.hostSwitches.isOn(.herdrApp)
        TerminalHostRow(host: .herdrApp, version: state.installed ? state.version ?? "Unknown" : "Not installed",
                        badge: row.badge,
                        diagnostics: diagnosticsText(state.diagnostics, shown: on),
                        problems: row.problems, sheet: $sheet) {
            HostSwitch(label: "Enable Herdr app", isOn: model.hostSwitchBinding(.herdrApp))
        } line: { CardProblemLine($0.message) }
    }
}

/// The tmux card (product.md, "Agreed terminal host presentation"; #241). Shown since tmux's acceptance
/// run passed (#246, `TerminalHost.showsCard`). tmux has no Permission row.
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

/// The Zellij card (product.md, "Agreed terminal host presentation"; #242). Shown since Zellij's acceptance
/// run passed (#247, `TerminalHost.showsCard`). Zellij has no Permission row.
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

/// Settings › Notifications (#317): the sound switch and tiles, the read-state switch, the response length, phone
/// alerts, what still pops open while paused (#456), and the test notification buttons. No footers.
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
                SettingsRow(title: "Response length", detail: nil) {
                    SlidingSegments(title: "Response length on result cards",
                                    selection: $model.resultResponseLength.animation(SettingsMotion.curve(reduceMotion: model.reduceMotion)),
                                    options: ResultResponseLength.allCases.map { ($0, $0.title) })
                }
                .help("How much of the last message each result card shows: all of it, its first five lines, or its first line. Show all on a card opens the rest.")
            }

            if model.phoneAlerts.available {
                PhoneSection(phone: model.phoneAlerts, reduceMotion: model.reduceMotion)
            }

            WhilePausedSection(model: model)

            HStack(spacing: 8) {
                Spacer()
                if model.attention.pending {
                    Button("Dismiss", action: model.dismissTest)
                        .accessibilityLabel("Dismiss test notification")
                }
                PhoneTestButton(phone: model.phoneAlerts)
                Button("Send Test Notification", action: model.sendTest)
            }
            .padding(.top, 6)
        }
    }
}

/// Settings › Notifications › While paused (#456): whether an approval or a question that arrives
/// while notifications are paused from the menu bar still pops open, or waits quietly in the queue.
/// Completions are always quiet while paused, so they have no row.
private struct WhilePausedSection: View {
    @ObservedObject var model: Companion

    var body: some View {
        SettingsHeader("While paused")
        SettingsCard {
            row(title: "Approvals", selection: $model.pausedNotifications.approvals)
            Divider().padding(.horizontal, SettingsStyle.rowInset)
            row(title: "Questions", selection: $model.pausedNotifications.questions)
        }
    }

    private func row(title: String, selection: Binding<PausedInterruption>) -> some View {
        SettingsRow(title: title, detail: nil) {
            SlidingSegments(title: "\(title) while notifications are paused",
                            selection: selection.animation(SettingsMotion.curve(reduceMotion: model.reduceMotion)),
                            options: PausedInterruption.allCases.map { ($0, $0.title) })
        }
        .help("While notifications are paused from the menu bar, new \(title.lowercased()) still open their card, play their sound and alert your phone, or wait quietly in the queue.")
    }
}

/// Settings › Notifications › Phone (#352, Paper "01 · Agreed · Send to phone (on)"): the switch,
/// and while it is on the topic in monospace with Copy. A failed test shows the orange line below.
private struct PhoneSection: View {
    @ObservedObject var phone: PhoneAlerts
    let reduceMotion: Bool

    var body: some View {
        SettingsHeader("Phone")
        SettingsCard {
            SettingsRow(title: "Alert my phone when I'm away",
                        detail: "Approvals, questions and completions, after \(PhoneAlertPolicy.idleThresholdText) idle") {
                Toggle("Alert my phone when I'm away",
                       isOn: Binding(get: { phone.enabled }, set: { enabled in
                           withAnimation(SettingsMotion.curve(reduceMotion: reduceMotion)) { _ = phone.setEnabled(enabled) }
                       }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .accessibilityLabel("Alert my phone when I'm away")
                    .accessibilityHint("Sends approvals, questions and completions to ntfy after \(PhoneAlertPolicy.idleThresholdText) idle.")
            }
            if phone.enabled {
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Topic", detail: "Subscribe to it in ntfy. Anyone with it can read your alerts.") {
                    HStack(spacing: 8) {
                        Text(topicText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(phone.topic == nil ? .secondary : .primary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .accessibilityLabel("Topic \(topicText)")
                        Button("Copy", action: phone.copyTopic)
                            .controlSize(.small)
                            .disabled(phone.topic == nil)
                            .accessibilityLabel("Copy topic")
                            .accessibilityHint("Copies the ntfy topic to subscribe to on your phone.")
                    }
                }
            }
            if let problem = phone.problem {
                CardProblemLine(problem)
                    .padding(.horizontal, SettingsStyle.rowInset)
                    .padding(.bottom, 10)
            }
        }
        .onAppear { phone.start() }
    }

    private var topicText: String {
        switch phone.topicState {
        case let .ready(topic): topic.name
        case .notLoaded, .loading: "Loading…"
        case .unavailable: "Unavailable"
        }
    }
}

/// "Send Test to Phone", beside "Send Test Notification", only while phone alerts are on.
private struct PhoneTestButton: View {
    @ObservedObject var phone: PhoneAlerts

    var body: some View {
        if phone.enabled {
            Button("Send Test to Phone") { phone.sendTest() }
                .disabled(phone.testInFlight)
                .accessibilityLabel("Send test alert to phone")
                .accessibilityHint("Publishes one test alert to your ntfy topic.")
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

/// The About pane (Paper "About redesign (2026-11-25)", AB1–AB5, #483): the app icon, wordmark and
/// tagline; the copyable version pill; Send Feedback; everything Herdly works with; and a footer
/// pinned to the bottom holding Quit Herdly.
private struct AboutControls: View {
    let quit: () -> Void
    let sendFeedback: () -> Void
    private let version = AboutVersion(infoDictionary: Bundle.main.infoDictionary)

    var body: some View {
        ControlsPage(section: .about) {
            VStack(spacing: 0) {
                VStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 136, height: 136)
                    HerdlyWordmark()
                        .fill(.primary)
                        .frame(width: 128, height: 46)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Herdly")
                .accessibilityAddTraits(.isImage)
                Text("One notch for every local agent session: what's working, what needs you, and a way back to it.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 330)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                AboutVersionPill(version: version)
                    .padding(.top, 18)
                Button("Send Feedback", action: sendFeedback)
                    .buttonStyle(.link)
                    .font(.system(size: 13))
                    .accessibilityHint("Opens a form to send a note to the Herdly team.")
                    .padding(.top, 16)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)

            SettingsHeader("Works with")
            SettingsCard {
                AboutTagRow(title: "Agents", tags: AboutWorksWith.agents)
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                AboutTagRow(title: "Terminals", tags: AboutWorksWith.terminals)
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                AboutTagRow(title: "Multiplexers", tags: AboutWorksWith.multiplexers)
            }
        } footer: {
            HStack(spacing: 16) {
                Text("Made for people running more agents than tabs.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Quit Herdly", action: quit)
                    .accessibilityHint("Stops Herdly and closes its menu-bar companion.")
            }
            .padding(.horizontal, SettingsStyle.rowInset)
            .frame(maxWidth: 620)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }
}

/// The version in a capsule: "0.1.0" with " (build N)" dimmed, then a copy glyph. A click copies
/// "0.1.0 (N)" and the pill reads "Copied" for 1.5 s, announced to VoiceOver.
private struct AboutVersionPill: View {
    let version: AboutVersion
    @State private var copies = 0
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 8) {
                // "Copied" sits over the hidden version text, so the capsule keeps its width and
                // nothing around it reflows.
                HStack(spacing: 0) {
                    Text(version.primaryText).foregroundStyle(.primary)
                    if let build = version.buildText { Text(build).foregroundStyle(.tertiary) }
                }
                .opacity(copied ? 0 : 1)
                .overlay {
                    if copied { Text("Copied").foregroundStyle(.primary) }
                }
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .padding(.vertical, 5)
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .background(SettingsStyle.sectionFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressFeedback())
        .help("Copy version")
        .accessibilityLabel(copied ? "Copied" : version.accessibilityLabel)
        .accessibilityHint("Copies the version to the clipboard.")
        // Restarts on every click, so the last click keeps "Copied" up for its full 1.5 s.
        .task(id: copies) {
            guard copies > 0 else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(version.copyText, forType: .string)
        copied = true
        copies += 1
        if NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "Copied \(version.copyText)",
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}

/// A Works with row: the label in a fixed 92pt column, then its values as tags, right-aligned and
/// wrapping. The tags are not interactive.
private struct AboutTagRow: View {
    let title: String
    let tags: [String]

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title).frame(width: 92, alignment: .leading)
            WrappingRow(spacing: 6, alignment: .trailing) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: .rect(cornerRadius: 7, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, SettingsStyle.rowInset)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(tags.joined(separator: ", "))
    }
}

/// The General pane holds the notch preview, the Display, Strip, Sprite and Session list choices
/// (ending with Keep new cards open), and Launch at login under Startup; every change applies at once.
private struct GeneralControls: View {
    @ObservedObject var model: Companion

    private var appearance: NotchAppearance { model.appearance }
    private var profile: DisplayProfile { model.activeProfile }

    private func binding<Value>(_ field: WritableKeyPath<NotchAppearance, Value>) -> Binding<Value> {
        Binding(get: { appearance[keyPath: field] }, set: { value in
            var updated = appearance
            updated[keyPath: field] = value
            withAnimation(SettingsMotion.curve(reduceMotion: model.reduceMotion)) {
                model.setAppearance(updated)
            }
        })
    }

    var body: some View {
        ControlsPage(section: .general) {
            SettingsHeader("Preview")
            NotchPreview(appearance: appearance, profile: profile, reduceMotion: model.reduceMotion)
                .animation(SettingsMotion.curve(reduceMotion: model.reduceMotion), value: appearance)
                .animation(SettingsMotion.curve(reduceMotion: model.reduceMotion), value: profile)

            SettingsHeader("Display")
            SettingsCard {
                SettingsRow(title: "Show notch on", detail: nil) {
                    FormMenu(title: "Show notch on", selection: Binding(
                        get: { model.notchDisplayChoices.selected.preference },
                        set: { preference in model.setNotchDisplayPreference(preference) }
                    ), options: model.notchDisplayChoices.options.map { ($0.preference, $0.label) })
                    .accessibilityHint(model.notchDisplayChoices.detail)
                }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                KeyboardHotkeyRow(model: model)
            }

            SettingsHeader("Strip")
            SettingsCard {
                SettingsRow(title: "Left side", detail: nil) {
                    SlidingSegments(title: "Left side", selection: binding(\.leftWing),
                                    options: [(StripLeftWing.spritesAndCount, "Sprites and count"), (StripLeftWing.countOnly, "Count only"), (StripLeftWing.none, "None")])
                }
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                // The choice applies on every display without a camera housing; the hover text says so.
                SettingsRow(title: "Center label", detail: nil) {
                    SlidingSegments(title: "Center label", selection: binding(\.centerLabel),
                                    options: [(StripCenterLabel.taskName, "Task name"), (StripCenterLabel.sessionName, "Session name"), (StripCenterLabel.off, "Off")])
                }
                .contentShape(Rectangle())
                .help("Text in the middle of the strip naming the top item. External displays only; on a MacBook the camera covers that space.")
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Usage limits", detail: nil) {
                    SlidingSegments(title: "Usage limits", selection: binding(\.usage),
                                    options: [(UsageDisplay.compact, "Compact"), (UsageDisplay.weeklyOnly, "Weekly only"), (UsageDisplay.hidden, "Hidden")])
                }
            }

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
                SettingsRow(title: "After each name", detail: nil) {
                    FormMenu(title: "After each name", selection: binding(\.labelFormat),
                             options: [(.repoAtBranch, "Repo @ branch"), (.repoOnly, "Repo"), (.branchOnly, "Branch")])
                }
                PlaceSampleRow(sprite: appearance.sprite, format: appearance.labelFormat, reduceMotion: model.reduceMotion)
                    .animation(SettingsMotion.curve(reduceMotion: model.reduceMotion), value: appearance.labelFormat)
                    .padding(.horizontal, SettingsStyle.rowInset)
                    .padding(.bottom, 10)
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
                Divider().padding(.horizontal, SettingsStyle.rowInset)
                SettingsRow(title: "Keep new cards open", detail: nil) {
                    FormMenu(title: "Keep new cards open", selection: $model.cardOpenDuration,
                             options: CardOpenDuration.allCases.map { ($0, $0.title) },
                             dividerBefore: .untilIAct)
                }
            }

            SettingsHeader("Startup")
            SettingsCard {
                SettingsRow(title: "Launch at login", detail: nil) {
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
        }
    }
}

/// Settings › General › Keyboard (#427): the shortcut that puts the keyboard in the notch from any app,
/// a recorder to change it, and a switch to turn it off. Both take effect at once. A shortcut another
/// app holds shows the problem line, and the notch stays click-only until another is chosen.
private struct KeyboardHotkeyRow: View {
    @ObservedObject var model: Companion

    private var enabled: Binding<Bool> {
        Binding(get: { model.hotkeySetting.enabled }, set: { on in
            var setting = model.hotkeySetting
            setting.enabled = on
            model.setHotkeySetting(setting)
        })
    }

    var body: some View {
        SettingsRow(title: "Keyboard", detail: "Puts the keyboard in the notch from any app") {
            HStack(spacing: 10) {
                HotkeyRecorder(model: model)
                    .disabled(!model.hotkeySetting.enabled)
                Toggle("Notch hotkey", isOn: enabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .accessibilityLabel("Notch hotkey")
            }
        }
        .help("Press it again, or Escape, to give the keyboard back to the app you were using.")
        if model.hotkeySetting.enabled, let problem = model.hotkeyStatus.problemLine {
            CardProblemLine(problem)
                .padding(.horizontal, SettingsStyle.rowInset)
                .padding(.bottom, 10)
        }
    }
}

/// Shows the current shortcut; a click listens for the next key press with Control, Option or
/// Command and saves it. Escape alone cancels. The current shortcut is unregistered while it listens
/// so pressing it records it rather than opening the notch. Only key presses in this window are seen.
private struct HotkeyRecorder: View {
    @ObservedObject var model: Companion
    @State private var monitor: Any?
    @State private var rejected = false

    private var recording: Bool { monitor != nil }

    var body: some View {
        Button(action: { recording ? stop() : start() }) {
            Text(recording ? (rejected ? "Add ⌃, ⌥ or ⌘" : "Type shortcut…") : model.hotkeySetting.hotkey.title)
                .monospacedDigit()
                .frame(minWidth: 96)
        }
        .controlSize(.small)
        .accessibilityLabel("Notch hotkey shortcut")
        .accessibilityValue(recording ? "Recording. Press the new shortcut, or Escape to cancel." : model.hotkeySetting.hotkey.title)
        .accessibilityHint(recording ? "Escape cancels." : "Records a new shortcut.")
        .onDisappear(perform: stop)
    }

    private func start() {
        rejected = false
        model.setRecordingHotkey(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch NotchHotkeyRegistrar.recording(event) {
            case .cancel:
                stop()
            case .shortcut(let hotkey):
                var setting = model.hotkeySetting
                setting.hotkey = hotkey
                stop()
                model.setHotkeySetting(setting)
            case .ignore:
                rejected = true
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        rejected = false
        model.setRecordingHotkey(false)
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

/// A sample queue row under "After each name": the chosen sprite idle in the first session colour,
/// a fixed title, then the place in the chosen format. It follows the Paper artboard, not the
/// notch's row header: system 12pt text (#F5F5F7 title, #8F8F8F place) on a black well. Display only.
private struct PlaceSampleRow: View {
    let sprite: SpriteKind
    let format: QueueLabelFormat
    let reduceMotion: Bool

    private static let sampleTitle = "Fix flaky tests"
    /// The sample's title colour, #F5F5F7; the notch has no token this bright.
    private static let titleColor = Color(red: 0.961, green: 0.961, blue: 0.969)

    /// The place in the chosen format, or nil when the format shows nothing.
    private var place: String? {
        QueueRowPresentation.place(directory: "/Users/you/code/herdly", branch: "main", format: format)
    }

    /// What follows the title on screen ("· herdly @ main") and the matching VoiceOver label, from
    /// the same place so the two never disagree.
    private var placeSuffix: String { place.map { " · \($0)" } ?? "" }
    private var spokenLabel: String {
        "Sample row: \(Self.sampleTitle)" + (place.map { ", \($0)" } ?? "")
    }

    var body: some View {
        HStack(spacing: 7) {
            Sprite(kind: sprite, working: false, reduceMotion: reduceMotion, color: 0)
            Text("\(Text(Self.sampleTitle).foregroundStyle(Self.titleColor))\(Text(placeSuffix).foregroundStyle(NotchStyle.text))")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
        .background(NotchStyle.ground, in: .rect(cornerRadius: 9, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
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
