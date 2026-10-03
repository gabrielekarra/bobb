import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech
import BobbCore

/// Talking to Bobb, like Siri, but the words never leave the Mac:
/// recognition is required to run on-device, and when the user's language
/// is not available offline Bobb says so instead of sending audio to a
/// server. Listens until the user stops talking for a moment, then hands
/// the sentence to the command bar.
@MainActor
@Observable
final class SpeechInput {
    enum Phase: Equatable {
        case idle
        case starting
        case listening
        case unavailable(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    @ObservationIgnored var onTranscript: ((String) -> Void)?
    @ObservationIgnored var onFinish: ((String) -> Void)?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private var silence: Timer?
    @ObservationIgnored private var generation = UUID()
    /// How long a pause ends the sentence.
    @ObservationIgnored var pause: TimeInterval = 1.4

    var isListening: Bool { phase == .listening }
    var isActive: Bool { phase == .starting || isListening }

    func toggle(language: String) {
        isActive ? finish() : start(language: language)
    }

    func start(language: String) {
        guard !isActive else { return }
        transcript = ""
        generation = UUID()
        let token = generation
        phase = .starting
        // Permission callbacks arrive on a system queue. Explicit Sendable
        // prevents them inheriting MainActor isolation and trapping before
        // the hop back to the UI executor.
        SFSpeechRecognizer.requestAuthorization { @Sendable status in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.phase == .starting else { return }
                guard status == .authorized else {
                    self.phase = .unavailable(L10n.t(.voiceNotAllowed))
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { @Sendable granted in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.phase == .starting else { return }
                        guard granted else {
                            self.phase = .unavailable(L10n.t(.voiceNoMicrophone))
                            return
                        }
                        self.begin(language: language, token: token)
                    }
                }
            }
        }
    }

    private func begin(language: String, token: UUID) {
        let locale = Locale(identifier: language == "it" ? "it-IT" : "en-US")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            phase = .unavailable(L10n.t(.voiceUnavailable))
            return
        }
        // The promise is that nothing leaves the Mac; a recognizer that
        // would need Apple's servers is not used.
        guard recognizer.supportsOnDeviceRecognition else {
            phase = .unavailable(L10n.t(.voiceNotOnDevice))
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        nonisolated(unsafe) let sink = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            sink.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            phase = .unavailable(L10n.t(.voiceNoMicrophone))
            return
        }
        phase = .listening
        recognition = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard self?.generation == token else { return }
                self?.heard(text, final: final, failed: failed)
            }
        }
        armSilence()
    }

    private func heard(_ text: String?, final: Bool, failed: Bool) {
        guard isListening else { return }
        if let text, !text.isEmpty {
            transcript = text
            onTranscript?(text)
            armSilence()
        }
        if final || failed { finish() }
    }

    private func armSilence() {
        silence?.invalidate()
        let token = generation
        silence = Timer.scheduledTimer(withTimeInterval: transcript.isEmpty ? 6 : pause, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.generation == token else { return }
                self?.finish()
            }
        }
    }

    /// Stops listening and hands over what was said.
    func finish() {
        if phase == .starting { cancel(); return }
        guard isListening else { return }
        generation = UUID()
        teardown()
        phase = .idle
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onFinish?(text) }
    }

    /// Stops listening and throws the words away.
    func cancel() {
        guard isActive else { return }
        generation = UUID()
        if isListening { teardown() }
        phase = .idle
        transcript = ""
    }

    private func teardown() {
        silence?.invalidate()
        silence = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognition?.cancel()
        request = nil
        recognition = nil
    }
}
