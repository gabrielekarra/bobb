import AppKit
import Observation
import SwiftUI
import BobbCore

/// The command bar's own state: what is being typed, over
/// which selection. The answer itself lives in `AppState.ask`.
@MainActor
@Observable
final class CommandBarModel {
    var input: String = ""
    var selection: Selection?
    var notice: String?
    @ObservationIgnored weak var field: NSTextField?

    func reset(with selection: Selection?) {
        self.selection = selection
        input = ""
        notice = nil
    }

}

extension AskMode {
    /// Modes whose output is meant to replace the selection.
    var replacesSelection: Bool { self == .rewrite || self == .translate }
}

/// The text field, as AppKit: SwiftUI's cannot be focused reliably in a
/// non-activating panel, and Escape must close it.
struct CommandInput: NSViewRepresentable {
    let model: CommandBarModel
    let placeholder: String
    let onSubmit: () -> Void
    let onEscape: () -> Void
    let onEdit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17, weight: .regular)
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        model.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != model.input { field.stringValue = model.input }
        field.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandInput

        init(parent: CommandInput) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onEdit()
            parent.model.input = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}

struct CommandBarView: View {
    @Bindable var state: AppState
    @Bindable var model: CommandBarModel
    var speech: SpeechInput?
    let submit: () -> Void
    let close: () -> Void
    let apply: (String) -> Void
    let stop: () -> Void
    var toggleVoice: () -> Void = {}
    var endVoice: () -> Void = {}

    private var ask: AskSession { state.ask }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            if let selection = model.selection {
                selectionPreview(selection)
            }
            if let speech {
                if speech.isListening {
                    Label(L10n.t(.voiceListening), systemImage: "waveform")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.attention)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 10)
                } else if case .unavailable(let reason) = speech.phase {
                    Label(reason, systemImage: "mic.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 10)
                }
            }
            if ask.hasAnswer || ask.streaming {
                Divider()
                answer
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
            }
            Divider()
            hint
        }
        .frame(width: 680)
        .tint(Theme.accent)
    }

    private var inputRow: some View {
        HStack(spacing: 12) {
            BobbMark(size: 26, color: Theme.accentInk)
            CommandInput(
                model: model,
                placeholder: BobbCopy.t("Ask anything, or tell me what to do…", "Chiedimi qualcosa, o dimmi cosa fare…"),
                onSubmit: submit,
                onEscape: close,
                onEdit: endVoice
            )
            .frame(height: 26)
            if ask.streaming {
                Button(L10n.t(.askStop), action: stop)
                    .buttonStyle(QuietButtonStyle())
            }
            if let speech {
                Button(action: toggleVoice) {
                    Image(systemName: speech.isActive ? "waveform" : "mic")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(speech.isActive ? Theme.attention : Color.secondary)
                        .frame(width: 26, height: 26)
                        .background(speech.isActive ? Theme.attention.opacity(0.15) : Color.clear, in: Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.t(.voiceTalk))
                .keyboardShortcut("d", modifiers: .command)
            }
        }
    }

    private func selectionPreview(_ selection: Selection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Theme.sectionTitle(L10n.t(.askSelectionLabel, ["app": selection.app]))
            Text(selection.text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Group {
                    if let error = ask.error {
                        Label(L10n.t(.askError, ["detail": error]), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else if ask.text.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(L10n.t(.askWorking)).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(markdown(ask.text))
                            .textSelection(.enabled)
                    }
                }
                .font(.system(size: 13.5))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)

            if !ask.unsupported.isEmpty && !ask.streaming {
                FlowRow { ForEach(ask.unsupported, id: \.self) { CheckChip(text: $0) } }
            }
            if !ask.sources.isEmpty && !ask.streaming {
                VStack(alignment: .leading, spacing: 4) {
                    Theme.sectionTitle(L10n.t(.askSources))
                    FlowRow {
                        ForEach(ask.sources) { source in
                            Pill(text: source.label + " · " + L10n.relative(source.lastSeen))
                        }
                    }
                }
            }
            if !ask.streaming && ask.error == nil && !ask.text.isEmpty {
                HStack {
                    if let notice = model.notice {
                        Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.t(.askCopy)) {
                        Clipboard.copy(ask.text)
                        model.notice = L10n.t(.draftCopied)
                    }
                    .buttonStyle(QuietButtonStyle())
                    if model.selection != nil || ask.mode == .write || ask.mode == .reply {
                        Button(ask.mode.replacesSelection ? L10n.t(.askReplace) : L10n.t(.askInsert)) { apply(ask.text) }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
        }
        .padding(18)
    }

    private var hint: some View {
        HStack {
            Text(L10n.t(.askHint))
            Spacer()
            Image(systemName: "lock.fill").font(.system(size: 9))
            Text("On-device")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// A borderless panel that takes keyboard focus without activating Bobb,
/// so the app the user was in stays frontmost behind it.
final class CommandPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 120),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        self.contentView = BobbGlassHostingView(contentView, radius: 28)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        // Clicking anywhere else closes it, like Spotlight.
        orderOut(nil)
    }
}

@MainActor
final class CommandBarController {
    private let state: AppState
    private let coordinator: BobbCoordinator
    private let model = CommandBarModel()
    private var panel: CommandPanel?
    private var hosting: NSHostingView<CommandBarView>?
    private var sizeObservation: NSKeyValueObservation?
    /// Starts a task; returns why it cannot, in the user's words, or nil.
    var startTask: ((String, URL?, String?) -> String?)?
    private var sourceApp: String?
    let speech = SpeechInput()
    private let voice = ResponseVoice()

    init(state: AppState, coordinator: BobbCoordinator) {
        self.state = state
        self.coordinator = coordinator
        observeRouting()
        speech.onTranscript = { [weak self] text in self?.model.input = text }
        speech.onFinish = { [weak self] text in
            self?.model.input = text
            self?.submit(inputSource: .microphone)
        }
        voice.onError = { [weak self] error in self?.model.notice = error }
        coordinator.onAnswer = { [weak self] answer in
            guard let self, self.panel?.isVisible == true, self.state.consumeSpokenAnswer(answer) else { return }
            self.voice.speak(answer.text, settings: self.state.settings, permitted: { [weak self] in
                guard let self else { return false }
                return self.panel?.isVisible == true && !self.speech.isActive
                    && self.state.permitsSpokenResponse(requestId: answer.requestId)
            })
        }
    }

    /// Opens the bar already listening: talk instead of type.
    func listen() {
        if panel?.isVisible != true { show(selection: nil) }
        guard !speech.isActive else { return }
        startVoiceTurn()
    }

    private func toggleVoice() {
        if speech.isActive { speech.finish() } else { startVoiceTurn() }
    }

    private func startVoiceTurn() {
        model.notice = nil
        endVoiceConversation()
        coordinator.cancelAsk()
        speech.start(language: L10n.code)
    }

    private func endVoiceConversation() {
        speech.cancel()
        state.endVoiceConversation()
        voice.stop()
    }

    private func stopAnswer() {
        endVoiceConversation()
        coordinator.cancelAsk()
    }

    /// A request the daemon judged to be something to do becomes a task.
    private func observeRouting() {
        withObservationTracking {
            _ = state.ask.taskGoal
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let goal = self.state.ask.taskGoal {
                    let destination = self.state.ask.taskURL
                    self.state.ask.taskGoal = nil
                    self.state.ask.taskURL = nil
                    self.beginTask(goal, destination: destination)
                }
                self.observeRouting()
            }
        }
    }

    private func beginTask(_ goal: String, destination: String?) {
        var url: URL?
        if let destination {
            guard let candidate = URL(string: destination), ["https", "http"].contains(candidate.scheme ?? ""),
                  candidate.host != nil, candidate.user == nil, candidate.password == nil else {
                state.ask.error = BobbCopy.t("The website address is invalid.", "L’indirizzo del sito non è valido.")
                return
            }
            url = candidate
        }
        if let problem = startTask?(goal, url, sourceApp) {
            state.ask = AskSession()
            state.ask.error = problem
            return
        }
        state.ask = AskSession()
        close()
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
            return
        }
        Task {
            let selection = await SelectionReader.current()
            show(selection: selection)
        }
    }

    func show(selection: Selection?) {
        endVoiceConversation()
        let front = NSWorkspace.shared.frontmostApplication
        sourceApp = selection?.bundleId ?? (front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front?.bundleIdentifier)
        model.reset(with: selection)
        if !state.ask.streaming { state.ask = AskSession() }
        if panel == nil {
            let view = CommandBarView(
                state: state, model: model, speech: speech,
                submit: { [weak self] in self?.submit() },
                close: { [weak self] in self?.close() },
                apply: { [weak self] text in self?.apply(text) },
                stop: { [weak self] in self?.stopAnswer() },
                toggleVoice: { [weak self] in self?.toggleVoice() },
                endVoice: { [weak self] in self?.endVoiceConversation() }
            )
            let hosting = NSHostingView(rootView: view)
            hosting.sizingOptions = [.intrinsicContentSize]
            let panel = CommandPanel(contentView: hosting)
            self.hosting = hosting
            self.panel = panel
        }
        guard let panel, let hosting else { return }
        position(panel, size: hosting.fittingSize)
        panel.orderFrontRegardless()
        panel.makeKey()
        if let field = model.field { panel.makeFirstResponder(field) }
        observeSize()
    }

    /// Shared entry point for a prefilled request, also used by the real UI smoke check.
    func request(_ prompt: String, selection: Selection? = nil, allowActions: Bool = true) {
        show(selection: selection)
        model.input = prompt
        submit(allowActions: allowActions)
    }

    private func observeSize() {
        withObservationTracking {
            _ = state.ask.text
            _ = state.ask.streaming
            _ = state.ask.sources
            _ = model.selection
            _ = model.notice
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible, let hosting = self.hosting else { return }
                self.resize(panel, to: hosting.fittingSize)
                self.observeSize()
            }
        }
    }

    private func position(_ panel: NSPanel, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - visible.height * 0.22 - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func resize(_ panel: NSPanel, to size: NSSize) {
        var frame = panel.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        panel.setFrame(frame, display: true, animate: false)
    }

    private func submit(inputSource: AskInputSource = .keyboard, allowActions: Bool = true) {
        endVoiceConversation()
        model.notice = nil
        let prompt = model.input.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = model.selection
        guard !prompt.isEmpty || selection != nil else { return }
        guard state.connection.isReady else {
            state.ask = AskSession()
            state.ask.error = L10n.t(.askNotReady)
            return
        }
        coordinator.ask(
            prompt: prompt, mode: allowActions ? .auto : .ask, selection: selection?.text ?? "",
            app: selection?.app ?? "", window: selection?.window ?? "", route: allowActions && state.settings.actingEnabled,
            inputSource: inputSource
        )
        model.input = ""
    }

    private func apply(_ text: String) {
        let selection = model.selection
        close()
        Task {
            let outcome = await TextInserter.insert(text, into: selection)
            if case .copiedOnly = outcome {
                model.notice = L10n.t(.draftPasteHint)
            }
        }
    }

    func close() {
        endVoiceConversation()
        panel?.orderOut(nil)
    }
}
