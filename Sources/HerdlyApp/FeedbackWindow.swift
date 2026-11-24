import AppKit
import HerdlyCore
import SwiftUI
import UniformTypeIdentifiers

/// Send Feedback (Paper "Herdly Settings", page "Send feedback (2026-11-24)", frames 02–05): a small
/// native window opened from the menu bar item. It follows the Settings window's materials, not the
/// notch's. The note goes to the feedback relay; nothing is sent until the user presses Send.

/// Carries the one relay request; injected so tests and labs never reach the real relay.
protocol FeedbackTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// An ephemeral session with a bounded wait: no cookies, no cache, no retry behind the user's back.
struct URLSessionFeedbackTransport: FeedbackTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = FeedbackRelay.timeout
        configuration.timeoutIntervalForResource = FeedbackRelay.timeout + 10
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

@MainActor
final class FeedbackForm: ObservableObject {
    enum Phase: Equatable {
        case editing
        case sending
        case sent
    }

    @Published var draft = FeedbackDraft()
    @Published private(set) var phase = Phase.editing
    /// The footer's orange line after a failed send (frame 04); the draft is kept.
    @Published private(set) var problem: String?
    /// Why the last screenshot was turned away, shown beside the Screenshots label.
    @Published private(set) var attachmentNote: String?
    @Published var showDetails = false

    let details: FeedbackAppDetails
    private let endpoint: URL
    private let transport: any FeedbackTransport

    init(details: FeedbackAppDetails, endpoint: URL = FeedbackRelay.endpoint,
         transport: any FeedbackTransport = URLSessionFeedbackTransport()) {
        self.details = details
        self.endpoint = endpoint
        self.transport = transport
    }

    var canSend: Bool { draft.canSend && phase == .editing }

    func attach(fileAt url: URL) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // Check the size before reading, so a huge file never lands in memory.
        guard size > 0, draft.attachmentBytes + size <= FeedbackDraft.maxAttachmentBytes else {
            attachmentNote = size > 0 ? "Over 20 MB in all" : "Couldn't read that file"
            return
        }
        guard let data = try? Data(contentsOf: url),
              let attachment = FeedbackAttachment(filename: url.lastPathComponent, data: data) else {
            attachmentNote = "Images only"
            return
        }
        switch draft.add(attachment) {
        case .added: attachmentNote = nil
        case .tooMany: attachmentNote = "Up to 5 images"
        case .tooLarge: attachmentNote = "Over 20 MB in all"
        }
    }

    func remove(_ attachment: FeedbackAttachment) {
        draft.removeAttachment(id: attachment.id)
        attachmentNote = nil
    }

    func send() async {
        guard canSend,
              let request = FeedbackRelay.request(draft: draft, details: details, endpoint: endpoint) else { return }
        phase = .sending
        problem = nil
        let outcome: FeedbackSendOutcome
        do {
            let (_, response) = try await transport.data(for: request)
            outcome = (response as? HTTPURLResponse).map { FeedbackRelay.outcome(statusCode: $0.statusCode) }
                ?? FeedbackRelay.offline
        } catch {
            outcome = FeedbackRelay.offline
        }
        switch outcome {
        case .sent:
            phase = .sent
        case .failed(let line):
            problem = line
            phase = .editing
        }
    }
}

@MainActor
final class FeedbackWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeDetails: () -> FeedbackAppDetails

    init(details: @escaping () -> FeedbackAppDetails) {
        makeDetails = details
    }

    /// Brings the open window forward, keeping its draft; otherwise opens a fresh one.
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        let form = FeedbackForm(details: makeDetails())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Send Feedback"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = SettingsStyle.windowBackground
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hosting = NSHostingController(rootView: FeedbackView(form: form, close: { [weak self] in self?.close() }))
        hosting.sizingOptions = .preferredContentSize
        window.contentViewController = hosting
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var isOpen: Bool { window?.isVisible == true }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing ends the note; the next Send Feedback starts empty.
        window = nil
    }
}

private enum FeedbackStyle {
    static let fieldFill = SettingsStyle.sectionFill
    static let hairline = Color.primary.opacity(0.08)
    static let label = Font.system(size: 12, weight: .medium)
}

struct FeedbackView: View {
    @ObservedObject var form: FeedbackForm
    let close: () -> Void

    var body: some View {
        Group {
            if form.phase == .sent {
                FeedbackSentView(draft: form.draft, close: close)
            } else {
                FeedbackFormView(form: form, close: close)
            }
        }
        .frame(width: 460)
        .background(SettingsStyle.pageBackground)
    }
}

private struct FeedbackHeader: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("Send Feedback")
                .font(.system(size: 20, weight: .semibold))
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }
}

private struct FeedbackFormView: View {
    @ObservedObject var form: FeedbackForm
    let close: () -> Void
    @FocusState private var descriptionFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            FeedbackHeader()
            VStack(alignment: .leading, spacing: 18) {
                labeled("Kind") {
                    FeedbackPicker(title: "Kind", selection: $form.draft.kind, label: \.title)
                }
                labeled("Part of Herdly") {
                    FeedbackPicker(title: "Part of Herdly", selection: $form.draft.area, label: \.title)
                }
                labeled("What happened?") {
                    ZStack(alignment: .topLeading) {
                        if form.draft.description.isEmpty {
                            Text("What you did, what you expected, and what the notch did instead.")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        TextEditor(text: $form.draft.description)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .focused($descriptionFocused)
                            .accessibilityLabel("What happened?")
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .frame(height: 120)
                    .background(FeedbackStyle.fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(descriptionFocused ? Color.accentColor.opacity(0.8) : FeedbackStyle.hairline))
                }
                FeedbackScreenshots(form: form)
                FeedbackDetailsCard(form: form)
            }
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
            .disabled(form.phase == .sending)
            footer
        }
        .onAppear { descriptionFocused = true }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let problem = form.problem {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(.orange).frame(width: 7, height: 7)
                    Text(problem + " Your note is kept.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                FeedbackButtonLabel(title: "Cancel", hint: "esc")
            }
            .keyboardShortcut(.cancelAction)
            Button {
                Task { await form.send() }
            } label: {
                FeedbackButtonLabel(title: form.phase == .sending ? "Sending…"
                                    : form.problem == nil ? "Send Feedback" : "Try Again",
                                    hint: "⌘↩")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!form.canSend)
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .overlay(alignment: .top) { Rectangle().fill(FeedbackStyle.hairline).frame(height: 1) }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(FeedbackStyle.label).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A full-width field that opens a native menu (frame 02): the stock pop-up button sizes to its
/// longest item, so the field is drawn here and the menu keeps the system's check mark and keys.
private struct FeedbackPicker<Value: Hashable & CaseIterable>: View where Value.AllCases: RandomAccessCollection {
    let title: String
    @Binding var selection: Value
    let label: KeyPath<Value, String>

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(Array(Value.allCases), id: \.self) { Text($0[keyPath: label]).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(selection[keyPath: label])
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.leading, 10)
        .padding(.trailing, 26)
        .frame(maxWidth: .infinity, minHeight: 30)
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.trailing, 10)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background(FeedbackStyle.fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(FeedbackStyle.hairline))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityLabel(title)
        .accessibilityValue(selection[keyPath: label])
    }
}

/// A footer button's title with its key hint after it, as in frames 02–04.
private struct FeedbackButtonLabel: View {
    let title: String
    let hint: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Text(hint)
                .font(.system(size: 10))
                .opacity(0.6)
                .accessibilityHidden(true)
        }
    }
}

private struct FeedbackScreenshots: View {
    @ObservedObject var form: FeedbackForm
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Screenshots").font(FeedbackStyle.label).foregroundStyle(.secondary)
                Spacer()
                Text(form.attachmentNote ?? (form.draft.attachments.isEmpty
                                             ? "Up to 5 images" : "\(form.draft.attachments.count) of 5"))
                    .font(.system(size: 11))
                    .foregroundStyle(form.attachmentNote == nil ? Color.secondary : SettingsStyle.attentionText)
            }
            Group {
                if form.draft.attachments.isEmpty {
                    HStack(spacing: 10) {
                        Text("Drop images here, or").font(.system(size: 13)).foregroundStyle(.secondary)
                        Button("Choose…", action: choose)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(dropTargeted ? Color.accentColor : Color.primary.opacity(0.18),
                                      style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                } else {
                    HStack(spacing: 8) {
                        ForEach(form.draft.attachments) { attachment in
                            thumbnail(attachment)
                        }
                        if form.draft.attachments.count < FeedbackDraft.maxAttachments {
                            Button(action: choose) {
                                Image(systemName: "plus").font(.system(size: 15)).foregroundStyle(.secondary)
                                    .frame(width: 48, height: 48)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(dropTargeted ? Color.accentColor : Color.primary.opacity(0.18),
                                                      style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add screenshot")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 6)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in form.attach(fileAt: url) }
                    }
                }
                return true
            }
        }
    }

    private func thumbnail(_ attachment: FeedbackAttachment) -> some View {
        Group {
            if let image = NSImage(data: attachment.data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                FeedbackStyle.fieldFill
            }
        }
        .frame(width: 72, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .overlay(alignment: .topLeading) {
            Button { form.remove(attachment) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(white: 0.3))
            }
            .buttonStyle(.plain)
            .offset(x: -6, y: -6)
            .accessibilityLabel("Remove \(attachment.filename)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.filename)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .gif, .tiff]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { form.attach(fileAt: url) }
    }
}

private struct FeedbackDetailsCard: View {
    @ObservedObject var form: FeedbackForm

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include app details").font(.system(size: 13))
                    HStack(spacing: 0) {
                        Text("Version, macOS, and which agents and terminals are connected. Never your prompts or code. ")
                            .foregroundStyle(.secondary)
                        + Text(form.showDetails ? "Hide details" : "Show what's sent")
                            .foregroundStyle(Color.accentColor)
                    }
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { form.showDetails.toggle() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(form.showDetails ? "Hides the app details" : "Shows exactly what is sent")
                }
                Spacer(minLength: 0)
                Toggle("Include app details", isOn: $form.draft.includeDetails)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(FeedbackStyle.fieldFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            if form.showDetails {
                Text(form.details.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(FeedbackStyle.hairline))
            }
        }
    }
}

private struct FeedbackSentView: View {
    let draft: FeedbackDraft
    let close: () -> Void

    private var summary: String {
        let kind = switch draft.kind {
        case .bug: "bug report"
        case .idea: "idea"
        case .other: "note"
        }
        let about = draft.area == .notSure ? "" : " about \(draft.area.title)"
        var extras: [String] = []
        let shots = draft.attachments.count
        if shots > 0 { extras.append(shots == 1 ? "1 screenshot" : "\(shots) screenshots") }
        if draft.includeDetails { extras.append("app details") }
        let with = extras.isEmpty ? "" : ", with " + extras.joined(separator: " and ")
        return "Your \(kind)\(about) is on its way\(with)."
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(SettingsStyle.readyText)
                    .frame(width: 44, height: 44)
                    .background(SettingsStyle.readyText.opacity(0.14), in: Circle())
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)
                Text("Thanks, it's sent").font(.system(size: 20, weight: .semibold))
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 40)
            .padding(.top, 52)
            .padding(.bottom, 32)
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .overlay(alignment: .top) { Rectangle().fill(FeedbackStyle.hairline).frame(height: 1) }
        }
    }
}
