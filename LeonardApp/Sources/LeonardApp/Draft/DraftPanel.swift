import AppKit
import Observation
import SwiftUI
import LeonardCore

/// What the user has done to the draft on screen: their edits, the
/// instruction they are typing, and the outcome of the last action.
@MainActor
@Observable
final class DraftEditor {
    var text: String = ""
    var instruction: String = ""
    var notice: String?
    var edited = false
    fileprivate var sourceDecisionId: String?
    fileprivate var sourceText: String = ""

    /// Follows the streamed draft until the user starts editing it.
    func sync(with session: DraftSession?) {
        guard let session else { return }
        if session.decision.id != sourceDecisionId || (!edited && session.text != sourceText) {
            if session.decision.id != sourceDecisionId {
                edited = false
                notice = nil
                instruction = ""
            }
            sourceDecisionId = session.decision.id
            sourceText = session.text
            if !edited { text = session.text }
        }
    }
}

/// The draft Leonard wrote after "Prepare". It appears as it is written,
/// can be edited, rewritten in one click (accept, decline, need time, ask
/// for details) or with an instruction, and leaves only when the user sends
/// it somewhere — a Mail reply window, the text field they were in, or the
/// clipboard. It never sends anything itself.
struct DraftView: View {
    @Bindable var state: AppState
    @Bindable var editor: DraftEditor
    let coordinator: LeonardCoordinator
    let close: () -> Void
    let replyInMail: (String, String) -> Void
    let insert: (String) -> Void

    private var session: DraftSession? { state.draft }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            textArea
            if let result = session?.result, !result.unsupported.isEmpty, !editor.edited {
                FlowRow {
                    ForEach(result.unsupported, id: \.self) { CheckChip(text: $0) }
                }
            }
            if let sources = session?.result?.sources, !sources.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L10n.t(.draftSources))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    FlowRow {
                        ForEach(sources) { Pill(text: $0.label) }
                    }
                }
            }
            if session?.isReply == true {
                variants
            }
            instructionField
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 520)
        .tint(Theme.accent)
        .onAppear { editor.sync(with: session) }
        .onChange(of: session?.text) { _, _ in editor.sync(with: session) }
        .onChange(of: session?.decision.id) { _, _ in editor.sync(with: session) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            LeonardMark(size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(session?.title ?? L10n.t(.draftTitle))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                if session?.streaming == true {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(L10n.t(.draftWriting))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                } else if let detail = session?.decision.suggestion?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var textArea: some View {
        Group {
            if let error = session?.error {
                Label(L10n.t(.draftError) + " (\(error))", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            } else {
                TextEditor(text: Binding(
                    get: { editor.text },
                    set: { newValue in
                        if newValue != editor.text {
                            editor.text = newValue
                            if session?.streaming == false { editor.edited = true }
                        }
                    }
                ))
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .disabled(session?.streaming == true)
                .frame(minHeight: 160, maxHeight: 320)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous))
    }

    private var variants: some View {
        HStack(spacing: 6) {
            variant(L10n.t(.draftAccept), "accept")
            variant(L10n.t(.draftDecline), "decline")
            variant(L10n.t(.draftMoreTime), "more_time")
            variant(L10n.t(.draftAskDetails), "ask_details")
            Spacer()
        }
    }

    private func variant(_ title: String, _ key: String) -> some View {
        Button(title) {
            editor.edited = false
            coordinator.regenerate(instruction: key)
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(session?.streaming == true)
    }

    private var instructionField: some View {
        HStack(spacing: 8) {
            TextField(L10n.t(.draftInstructionPlaceholder), text: $editor.instruction)
                .textFieldStyle(.roundedBorder)
                .onSubmit { rewrite() }
            Button(L10n.t(.draftRegenerate)) { rewrite() }
                .buttonStyle(QuietButtonStyle())
                .disabled(session?.streaming == true)
        }
    }

    private func rewrite() {
        let instruction = editor.instruction.trimmingCharacters(in: .whitespaces)
        editor.edited = false
        coordinator.regenerate(instruction: instruction)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(editor.notice ?? L10n.t(.draftNeverSent))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            Button(L10n.t(.draftCopy)) {
                Clipboard.copy(editor.text)
                editor.notice = L10n.t(.draftCopied)
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(editor.text.isEmpty || session?.streaming == true)
            if let result = session?.result, result.resultKind == "reply", let messageId = result.messageId, !messageId.isEmpty {
                Button(L10n.t(.draftOpenInMail)) { replyInMail(messageId, editor.text) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(editor.text.isEmpty || session?.streaming == true)
            } else {
                Button(L10n.t(.draftInsert)) { insert(editor.text) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(editor.text.isEmpty || session?.streaming == true)
            }
        }
    }
}

/// Shows `DraftView` in a floating panel whenever a draft session starts.
@MainActor
final class DraftPanelController {
    private let state: AppState
    private let coordinator: LeonardCoordinator
    private let editor = DraftEditor()
    private var panel: NSPanel?

    init(state: AppState, coordinator: LeonardCoordinator) {
        self.state = state
        self.coordinator = coordinator
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = state.draft?.decision.id
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.draftChanged()
                self?.observe()
            }
        }
    }

    private func draftChanged() {
        if state.draft != nil {
            show()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func show() {
        if panel == nil {
            let view = DraftView(
                state: state, editor: editor, coordinator: coordinator,
                close: { [weak self] in self?.close() },
                replyInMail: { [weak self] messageId, body in self?.replyInMail(messageId: messageId, body: body) },
                insert: { [weak self] text in self?.insert(text) }
            )
            let hosting = NSHostingView(rootView: view)
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                backing: .buffered, defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = hosting
            panel.setContentSize(hosting.fittingSize)
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - 16, y: visible.maxY - 16))
            }
            self.panel = panel
        }
        editor.sync(with: state.draft)
        panel?.orderFrontRegardless()
        panel?.makeKey()
    }

    func close() {
        coordinator.closeDraft()
        panel?.orderOut(nil)
    }

    private func replyInMail(messageId: String, body: String) {
        panel?.orderOut(nil)
        Task {
            let outcome = await MailComposer.reply(messageId: messageId, body: body)
            switch outcome {
            case .opened:
                coordinator.closeDraft()
            case .notFound, .failed:
                Clipboard.copy(body)
                editor.notice = L10n.t(.draftPasteHint)
                panel?.orderFrontRegardless()
            }
        }
    }

    /// The chat app a reply belongs in, when the draft answers a
    /// conversation rather than an email.
    private var chatApp: String? {
        guard let id = state.draft?.decision.eventId,
              let entry = state.entries.first(where: { $0.event.id == id }), entry.event.kind == .messageOpened,
              case .string(let bundle)? = entry.event.payload.fields["bundle_id"], !bundle.isEmpty else { return nil }
        return bundle
    }

    private func insert(_ text: String) {
        panel?.orderOut(nil)
        if let bundle = chatApp {
            Task {
                if await ChatInserter.insert(text, bundleId: bundle) {
                    coordinator.closeDraft()
                } else {
                    Clipboard.copy(text)
                    editor.notice = L10n.t(.draftPasteHint)
                    panel?.orderFrontRegardless()
                }
            }
            return
        }
        Task {
            let outcome = await TextInserter.insert(text, into: nil)
            if case .copiedOnly = outcome {
                editor.notice = L10n.t(.draftPasteHint)
                panel?.orderFrontRegardless()
            } else {
                coordinator.closeDraft()
            }
        }
    }
}
