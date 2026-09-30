import Foundation
import Testing
@testable import BobbCore

@Suite("Contract frame round-trips")
struct FrameCodableTests {

    // MARK: - App → daemon

    @Test func helloRoundTrips() throws {
        let frame = OutgoingFrame.hello(HelloFrame(ts: 1758348600.0, client: "BobbApp", version: "0.1"))
        let data = try frame.encoded()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["t"] as? String == "hello")
        #expect(object["client"] as? String == "BobbApp")
        #expect(object["version"] as? String == "0.1")
        #expect(object["ts"] as? Double == 1758348600.0)
    }

    @Test func eventRoundTripsWithTypingAndIdle() throws {
        let payload = EventPayload(typing: true, idle: false, fields: [
            "sender": "Marco Rossi <marco@example.com>",
            "subject": "Preventivo revisione",
            "body": "Ciao, mi confermi ...",
            "thread_len": 3,
            "unread": true,
        ])
        let original = EventFrame(ts: 1758348602.104, id: "evt_01J8Z", kind: .mailOpened, app: "Mail", payload: payload)
        let data = try OutgoingFrame.event(original).encoded()

        let type = try FrameCodec.readType(from: data)
        #expect(type == "event")
        let decoded = try FrameCodec.payload(EventFrame.self, from: data)

        #expect(decoded.id == "evt_01J8Z")
        #expect(decoded.kind == .mailOpened)
        #expect(decoded.app == "Mail")
        #expect(decoded.payload.typing == true)
        #expect(decoded.payload.idle == false)
        #expect(decoded.payload["sender"]?.stringValue == "Marco Rossi <marco@example.com>")
        #expect(decoded.payload["thread_len"]?.numberValue == 3)
        #expect(decoded.payload["unread"]?.boolValue == true)
        #expect(decoded == original)
    }

    @Test func eventPayloadOmitsAbsentTypingAndIdle() throws {
        let payload = EventPayload(typing: nil, idle: nil, fields: ["title": "Untitled"])
        let event = EventFrame(kind: .windowChanged, app: "Safari", payload: payload)
        let data = try OutgoingFrame.event(event).encoded()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["typing"] == nil)
        #expect(object["idle"] == nil)

        let decoded = try FrameCodec.payload(EventFrame.self, from: data)
        #expect(decoded.payload.typing == nil)
        #expect(decoded.payload.idle == nil)
    }

    @Test func approveAndDismissRoundTrip() throws {
        let approve = OutgoingFrame.approve(DecisionResponseFrame(ts: 1758348611.0, decisionId: "dec_01J8Z"))
        let approveData = try approve.encoded()
        #expect(try FrameCodec.readType(from: approveData) == "approve")
        let decodedApprove = try FrameCodec.payload(DecisionResponseFrame.self, from: approveData)
        #expect(decodedApprove.decisionId == "dec_01J8Z")
        #expect(decodedApprove.ts == 1758348611.0)

        let dismiss = OutgoingFrame.dismiss(DecisionResponseFrame(ts: 1758348611.0, decisionId: "dec_01J8Z"))
        let dismissData = try dismiss.encoded()
        #expect(try FrameCodec.readType(from: dismissData) == "dismiss")
    }

    @Test func policyRoundTrips() throws {
        let frame = OutgoingFrame.policy(PolicyFrame(ts: 1758348611.0, floor: 0.60))
        let data = try frame.encoded()
        #expect(try FrameCodec.readType(from: data) == "policy")
        let decoded = try FrameCodec.payload(PolicyFrame.self, from: data)
        #expect(decoded.floor == 0.60)
    }

    @Test func captureFrameRoundTrips() throws {
        let frame = OutgoingFrame.frame(CaptureFrame(ts: 1.0, id: "evt_1", data: "iVBORw0KG=="))
        let data = try frame.encoded()
        #expect(try FrameCodec.readType(from: data) == "frame")
        let decoded = try FrameCodec.payload(CaptureFrame.self, from: data)
        #expect(decoded.id == "evt_1")
        #expect(decoded.data == "iVBORw0KG==")
    }

    // MARK: - Daemon → app

    @Test func readyDecodesFromContractExample() throws {
        let json = """
        {
          "t": "ready", "ts": 1758348600.0,
          "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
          "prime_ms": 477.0, "decide_ms": 149.8, "floor": 0.60
        }
        """
        let frame = try IncomingFrame.decode(from: Data(json.utf8))
        guard case .ready(let ready) = frame else { Issue.record("expected .ready"); return }
        #expect(ready.model == "mlx-community/Llama-3.2-3B-Instruct-4bit")
        #expect(ready.primeMs == 477.0)
        #expect(ready.decideMs == 149.8)
        #expect(ready.floor == 0.60)
    }

    @Test func traceDecodesFromContractExample() throws {
        let json = #"{"t":"trace","ts":1758348602.11,"event_id":"evt_01J8Z...","stage":"gate","detail":"skip 0.0014 < 0.005","ms":0.4}"#
        let frame = try IncomingFrame.decode(from: Data(json.utf8))
        guard case .trace(let trace) = frame else { Issue.record("expected .trace"); return }
        #expect(trace.eventId == "evt_01J8Z...")
        #expect(trace.stage == .gate)
        #expect(trace.detail == "skip 0.0014 < 0.005")
        #expect(trace.ms == 0.4)
    }

    @Test func traceToleratesUnknownStage() throws {
        let json = #"{"t":"trace","ts":1.0,"event_id":"e","stage":"future-stage","detail":"","ms":1.0}"#
        let frame = try IncomingFrame.decode(from: Data(json.utf8))
        guard case .trace(let trace) = frame else { Issue.record("expected .trace"); return }
        #expect(trace.stage == nil)
        #expect(trace.rawStage == "future-stage")
    }

    @Test func decisionDecodesFromContractExample() throws {
        let json = """
        {
          "t": "decision",
          "ts": 1758348602.246,
          "id": "dec_01J8Z...",
          "event_id": "evt_01J8Z...",
          "action": "suggest",
          "confidence": 0.83,
          "schema_mass": 0.997,
          "latency_ms": 142.1,
          "hypotheses": [
            {"intent": "reply_to_email", "p": 0.88},
            {"intent": "look_for_attachment", "p": 0.41}
          ],
          "readouts": [
            {
              "q": "reply_needed", "value": true, "p": 0.91, "schema_mass": 1.0,
              "probabilities": {"false": 0.09, "true": 0.91},
              "raw_probabilities": {"false": 0.09, "true": 0.91}
            },
            {
              "q": "urgency", "value": 3, "p": 0.74, "schema_mass": 0.99,
              "probabilities": {"0": 0.02, "1": 0.05, "2": 0.11, "3": 0.74, "4": 0.08},
              "raw_probabilities": {"0": 0.02, "1": 0.05, "2": 0.11, "3": 0.74, "4": 0.08}
            },
            {
              "q": "interrupt", "value": "suggest", "p": 0.83, "schema_mass": 0.99,
              "probabilities": {"ignore": 0.03, "wait": 0.09, "prepare": 0.05, "suggest": 0.83},
              "raw_probabilities": {"ignore": 0.03, "wait": 0.09, "prepare": 0.05, "suggest": 0.83}
            }
          ],
          "suggestion": {
            "title": "Vuoi che prepari una risposta a Marco?",
            "action_id": "draft_reply",
            "detail": "3 messaggi nel thread, ultimo di 2 giorni fa"
          },
          "why": "reply_needed true a 0.91, costo di interruzione basso (non sta scrivendo)"
        }
        """
        let frame = try IncomingFrame.decode(from: Data(json.utf8))
        guard case .decision(let decision) = frame else { Issue.record("expected .decision"); return }
        #expect(decision.id == "dec_01J8Z...")
        #expect(decision.eventId == "evt_01J8Z...")
        #expect(decision.action == .suggest)
        #expect(decision.confidence == 0.83)
        #expect(decision.schemaMass == 0.997)
        #expect(decision.latencyMs == 142.1)
        #expect(decision.hypotheses.count == 2)
        #expect(decision.hypotheses[0].intent == "reply_to_email")
        #expect(decision.readouts.count == 3)
        #expect(decision.readouts[0].value == .bool(true))
        #expect(decision.readouts[1].value == .number(3))
        #expect(decision.readouts[2].value == .string("suggest"))
        #expect(decision.readouts[0].probabilities["true"] == 0.91)
        #expect(decision.readouts[0].rawProbabilities["false"] == 0.09)
        #expect(decision.readouts[2].orderedProbabilities.first?.label == "suggest")
        #expect(decision.suggestion?.actionId == "draft_reply")
        #expect(decision.abstained == false)

        // Round trip: encode our model back out and decode again.
        let reencoded = try FrameCodec.data(type: "decision", payload: decision)
        let redecoded = try FrameCodec.payload(DecisionFrame.self, from: reencoded)
        #expect(redecoded == decision)
    }

    @Test func decisionWithoutAbstainedKeyDefaultsFalseAndOmitsOnEncode() throws {
        let json = #"{"t":"decision","ts":1,"id":"d","event_id":"e","action":"ignore","confidence":1.0,"schema_mass":1.0,"latency_ms":0.1,"why":"nothing here"}"#
        let frame = try IncomingFrame.decode(from: Data(json.utf8))
        guard case .decision(let decision) = frame else { Issue.record("expected .decision"); return }
        #expect(decision.abstained == false)
        #expect(decision.suggestion == nil)
        #expect(decision.hypotheses.isEmpty)
        #expect(decision.readouts.isEmpty)

        let data = try FrameCodec.data(type: "decision", payload: decision)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["abstained"] == nil)
        #expect(object["suggestion"] == nil)
    }

    @Test func decisionWithAbstainedTrueEncodesTheKey() throws {
        let decision = DecisionFrame(
            ts: 1, id: "d", eventId: "e", action: .wait, confidence: 0.5,
            schemaMass: 0.99, latencyMs: 10, why: "below floor", abstained: true
        )
        let data = try FrameCodec.data(type: "decision", payload: decision)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["abstained"] as? Bool == true)

        let redecoded = try FrameCodec.payload(DecisionFrame.self, from: data)
        #expect(redecoded.abstained == true)
    }

    @Test func readoutProbabilitiesDecodeAndOrderSensibly() throws {
        let json = #"""
        {"q":"urgency","value":3,"p":0.74,"schema_mass":0.99,
         "probabilities":{"0":0.02,"1":0.05,"2":0.19,"3":0.74,"4":0.0}}
        """#
        let readout = try FrameCodec.decoder.decode(Readout.self, from: Data(json.utf8))
        #expect(readout.probabilities["3"] == 0.74)
        #expect(readout.orderedProbabilities.map(\.label) == ["0", "1", "2", "3", "4"])

        let boolJSON = #"{"q":"reply_needed","value":true,"p":0.91,"schema_mass":1.0,"probabilities":{"true":0.91,"false":0.09}}"#
        let boolReadout = try FrameCodec.decoder.decode(Readout.self, from: Data(boolJSON.utf8))
        #expect(boolReadout.orderedProbabilities.map(\.label) == ["false", "true"])

        let choiceJSON = #"{"q":"interrupt","value":"suggest","p":0.51,"schema_mass":0.99,"probabilities":{"ignore":0.1,"wait":0.2,"prepare":0.19,"suggest":0.51}}"#
        let choiceReadout = try FrameCodec.decoder.decode(Readout.self, from: Data(choiceJSON.utf8))
        #expect(choiceReadout.orderedProbabilities.first?.label == "suggest")
    }

    @Test func readoutProbabilitiesDefaultEmptyWhenAbsent() throws {
        let json = #"{"q":"reply_needed","value":true,"p":0.91,"schema_mass":1.0}"#
        let readout = try FrameCodec.decoder.decode(Readout.self, from: Data(json.utf8))
        #expect(readout.probabilities.isEmpty)
        #expect(readout.orderedProbabilities.isEmpty)
    }

    @Test func preparedRoundTrips() throws {
        let json = """
        {
          "t": "prepared", "ts": 1758348613.9,
          "decision_id": "dec_01J8Z...",
          "action_id": "draft_reply",
          "result": {"kind": "text", "body": "Ciao Marco, ..."},
          "latency_ms": 1740.0
        }
        """
        let frame = try IncomingFrame.decode(from: Data(json.utf8))
        guard case .prepared(let prepared) = frame else { Issue.record("expected .prepared"); return }
        #expect(prepared.decisionId == "dec_01J8Z...")
        #expect(prepared.actionId == "draft_reply")
        #expect(prepared.result["kind"]?.stringValue == "text")
        #expect(prepared.result["body"]?.stringValue == "Ciao Marco, ...")
        #expect(prepared.latencyMs == 1740.0)
    }

    @Test func observeFrameRoundTrips() throws {
        let candidates = [
            Candidate(id: "c1", label: "Rispondi", role: "AXButton", enabled: true),
            Candidate(id: "c2", label: "Campo testo messaggio", role: "AXTextArea", enabled: true),
            Candidate(id: "c3", label: "Archivia", role: "AXButton", enabled: true),
            Candidate(id: "done", label: "L'obiettivo è raggiunto", role: "-", enabled: true),
            Candidate(id: "escalate", label: "Nessuna di queste; serve ripianificare", role: "-", enabled: true),
        ]
        let observe = ObserveFrame(
            ts: 1758348620.0, id: "obs_01J8Z", goal: "Rispondere a Marco sul preventivo",
            app: "Mail", window: "Preventivo revisione", step: 3, candidates: candidates, digest: "sha256:abc"
        )
        let data = try OutgoingFrame.observe(observe).encoded()
        #expect(try FrameCodec.readType(from: data) == "observe")
        let decoded = try FrameCodec.payload(ObserveFrame.self, from: data)
        #expect(decoded == observe)
        #expect(decoded.candidates.count == 5)
        #expect(decoded.candidates.last?.id == "escalate")
    }

    @Test func actFrameDecodesFromContractExample() throws {
        let json = """
        {
          "t": "act",
          "ts": 1758348620.2,
          "observation_id": "obs_01J8Z...",
          "operation": "CLICK",
          "candidate_id": "c1",
          "confidence": 0.88,
          "schema_mass": 0.997,
          "operation_probabilities": {"CLICK": 0.88, "TYPE_TEXT": 0.07, "SCROLL_DOWN": 0.02, "DONE": 0.02, "BLOCKED": 0.01},
          "probabilities": {"c1": 0.91, "c2": 0.05, "c3": 0.01, "done": 0.02, "escalate": 0.01},
          "text": null,
          "latency_ms": 11.4,
          "abstained": false,
          "why": "obiettivo è una risposta; Rispondi è l'unico controllo che la apre"
        }
        """
        let frame = try IncomingFrame.decode(from: Data(json.utf8))
        guard case .act(let act) = frame else { Issue.record("expected .act"); return }
        #expect(act.observationId == "obs_01J8Z...")
        #expect(act.operation == .click)
        #expect(act.candidateId == "c1")
        #expect(act.text == nil)
        #expect(act.operationProbabilities["CLICK"] == 0.88)
        #expect(act.probabilities["c1"] == 0.91)
        #expect(act.abstained == false)

        let reencoded = try FrameCodec.data(type: "act", payload: act)
        let object = try #require(try JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect(object["text"] is NSNull)
        #expect(object["abstained"] == nil)
    }

    @Test func actFrameBelowFloorIsBlockedAndAbstained() throws {
        let json = """
        {"t":"act","ts":1,"observation_id":"o1","operation":"BLOCKED","candidate_id":"escalate",
         "confidence":0.2,"schema_mass":0.99,"latency_ms":5,"abstained":true,"why":"sotto la soglia"}
        """
        let frame = try IncomingFrame.decode(from: Data(json.utf8))
        guard case .act(let act) = frame else { Issue.record("expected .act"); return }
        #expect(act.operation == .blocked)
        #expect(act.candidateId == "escalate")
        #expect(act.abstained == true)
    }

    @Test func actFrameWithTypeTextCarriesGeneratedText() throws {
        let json = """
        {"t":"act","ts":1,"observation_id":"o1","operation":"TYPE_TEXT","candidate_id":"c2",
         "confidence":0.7,"schema_mass":0.99,"text":"Ciao Marco, confermo.","latency_ms":900}
        """
        let frame = try IncomingFrame.decode(from: Data(json.utf8))
        guard case .act(let act) = frame else { Issue.record("expected .act"); return }
        #expect(act.operation == .typeText)
        #expect(act.text == "Ciao Marco, confermo.")
    }

    @Test func errorFrameRoundTrips() throws {
        let json = #"{"t":"error","ts":1.0,"detail":"malformed json"}"#
        let frame = try IncomingFrame.decode(from: Data(json.utf8))
        guard case .error(let error) = frame else { Issue.record("expected .error"); return }
        #expect(error.detail == "malformed json")
    }
}
