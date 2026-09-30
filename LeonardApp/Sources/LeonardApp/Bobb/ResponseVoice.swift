import AVFoundation
import LeonardCore

@MainActor
final class ResponseVoice {
    private let synthesizer = AVSpeechSynthesizer()
    func speak(_ text: String, settings: LeonardSettings) {
        guard settings.bobb.speakResponses, !text.isEmpty else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        if let hours = settings.quietHours {
            let quiet = hours[0] < hours[1] ? (hours[0]..<hours[1]).contains(hour) : hour >= hours[0] || hour < hours[1]
            if quiet { return }
        }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: String(text.prefix(5000)))
        utterance.voice = AVSpeechSynthesisVoice(language: settings.language.code == "it" ? "it-IT" : "en-US")
        synthesizer.speak(utterance)
    }
    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}
