import Foundation
import Testing
@testable import BobbCore

@MainActor
@Suite("Voice replies require the current microphone turn")
struct VoiceResponseTests {
    private func answer(_ id: String = "voice", text: String = "Risposta", kind: String? = nil,
                        ok: Bool = true, cancelled: Bool? = nil) -> AnswerFrame {
        AnswerFrame(ts: 0, requestId: id, ok: ok, text: text, resultKind: kind, cancelled: cancelled)
    }

    @Test func typedRequestsStaySilent() {
        let state = AppState()
        state.beginAsk(AskFrame(id: "typed", prompt: "Una domanda"), mode: .ask)
        let response = answer("typed")
        state.applyAnswer(response)
        #expect(!state.consumeSpokenAnswer(response))
        #expect(!state.permitsSpokenResponse(requestId: "typed"))
        #expect(state.ask.text == "Risposta")
    }

    @Test func oneMicrophoneTurnCanSpeakOneAnswerIncludingClarification() {
        let state = AppState()
        state.beginAsk(AskFrame(id: "voice", prompt: "Una domanda"), mode: .auto, inputSource: .microphone)
        let response = answer(kind: "clarification")
        state.applyAnswer(response)
        #expect(state.consumeSpokenAnswer(response))
        #expect(state.permitsSpokenResponse(requestId: "voice"))
        #expect(!state.consumeSpokenAnswer(response))
    }

    @Test func typingANewRequestRevokesAudioAndRejectsLateVoiceReplies() {
        let state = AppState()
        state.beginAsk(AskFrame(id: "voice", prompt: "Parlato"), mode: .ask, inputSource: .microphone)
        #expect(state.consumeSpokenAnswer(answer()))
        state.beginAsk(AskFrame(id: "typed", prompt: "Scritto"), mode: .ask)
        #expect(!state.permitsSpokenResponse(requestId: "voice"))
        #expect(!state.consumeSpokenAnswer(answer()))
        #expect(!state.consumeSpokenAnswer(answer("typed")))
    }

    @Test func closingOrCancellingStopsPlaybackAndLateResponses() {
        let state = AppState()
        state.beginAsk(AskFrame(id: "voice", prompt: "Parlato"), mode: .ask, inputSource: .microphone)
        let response = answer()
        state.applyAnswer(response)
        #expect(state.consumeSpokenAnswer(response))
        state.endVoiceConversation()
        #expect(!state.permitsSpokenResponse(requestId: "voice"))
        #expect(!state.consumeSpokenAnswer(response))
        #expect(state.ask.text == "Risposta")
        state.beginAsk(AskFrame(id: "next", prompt: "Parlato"), mode: .ask, inputSource: .microphone)
        state.endVoiceConversation()
        #expect(!state.consumeSpokenAnswer(answer("next")))
    }

    @Test func backgroundAndRemoteRepliesCannotBorrowMicrophonePermission() {
        let state = AppState()
        state.beginAsk(AskFrame(id: "voice", prompt: "Parlato"), mode: .ask, inputSource: .microphone)
        for id in ["scheduled-report", "imessage", "previous-voice"] {
            #expect(!state.consumeSpokenAnswer(answer(id)))
            #expect(!state.permitsSpokenResponse(requestId: id))
        }
        #expect(state.consumeSpokenAnswer(answer()))
    }

    @Test func tasksErrorsAndCancelledAnswersDoNotStartAudio() {
        let state = AppState()
        for response in [answer(kind: "task"), answer(ok: false), answer(cancelled: true), answer(text: " \n ")] {
            state.beginAsk(AskFrame(id: "voice", prompt: "Parlato"), mode: .ask, inputSource: .microphone)
            #expect(!state.consumeSpokenAnswer(response))
            #expect(!state.permitsSpokenResponse(requestId: "voice"))
        }
    }

    @Test func theLegacyGlobalVoiceSwitchIsIgnoredWithoutLosingSettings() throws {
        var original = BobbWorkspaceSettings()
        original.activeAgent = "personal"
        original.backgroundEnabled = true
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["speakResponses"] = true
        let decoded = try JSONDecoder().decode(BobbWorkspaceSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == original)
        let saved = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!saved.contains("speakResponses"))
    }
}
