import Foundation
import Testing
@testable import LeonardCore

/// The two halves of the contract, checked against each other rather than
/// against a document. `Fixtures/daemon_frames.jsonl` is recorded from the
/// real Python daemon (`leonardd/tools/export_contract_fixtures.py`);
/// `Fixtures/app_frames.jsonl` is written by this suite and replayed into
/// the real daemon by `leonardd/tests/test_contract_fixtures.py`.
@Suite("Contract fixtures shared with leonardd")
struct ContractFixtureTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    private func daemonLines() throws -> [Data] {
        let text = try String(contentsOf: Self.fixtures.appendingPathComponent("daemon_frames.jsonl"), encoding: .utf8)
        return text.split(separator: "\n").map { Data($0.utf8) }
    }

    @Test func everyDaemonFrameDecodes() throws {
        let lines = try daemonLines()
        #expect(lines.count >= 15)
        var kinds: Set<String> = []
        for line in lines {
            let frame = try IncomingFrame.decode(from: line)
            switch frame {
            case .unknown(let type):
                // Echoes the app does not consume are allowed to be unknown.
                #expect(["settings", "memory.observed"].contains(type), "unexpected unknown frame \(type)")
            default:
                kinds.insert(String(describing: frame).components(separatedBy: "(").first ?? "")
            }
        }
        for expected in ["ready", "decision", "preparedDelta", "prepared", "answerDelta", "answer", "memoryResults",
                         "memoryStats", "stats", "memoryDeleted", "error", "act", "historyDeleted", "status"] {
            #expect(kinds.contains(expected), "no \(expected) frame in the fixture")
        }
    }

    @Test func decodedFramesCarryTheV1Fields() throws {
        for line in try daemonLines() {
            switch try IncomingFrame.decode(from: line) {
            case .ready(let ready):
                #expect(ready.protocolVersion == 1)
                #expect(ready.supports("ask"))
            case .decision(let decision):
                #expect(decision.explanation?.isEmpty == false)
                #expect(decision.suggestion?.cta?.isEmpty == false)
                #expect(decision.floor != nil)
            case .prepared(let prepared):
                #expect(prepared.resultKind == "reply")
                #expect(prepared.body.hasPrefix("Ciao Marco,"))
                #expect(prepared.replyTo?.contains("marco@studiorossi.it") == true)
                #expect(prepared.messageId == "<m1@studiorossi.it>")
            case .answer(let answer):
                #expect(answer.ok)
                #expect(answer.sources.first?.app == "Slack")
            case .memoryResults(let results):
                #expect(results.requestId == "req_search")
                #expect(results.results.first?.snippet.isEmpty == false)
            case .stats(let stats):
                #expect(stats.decisions.approved == 1)
            case .error(let error):
                #expect(error.requestId == "ask_empty")
            case .status(let status):
                #expect(status.isModelMissing)
            default:
                break
            }
        }
    }

    /// Every frame the app can send, as it encodes it. Rewritten on every
    /// run so the daemon-side test always replays what this build sends.
    @Test func appFramesAreWrittenForTheDaemonToReplay() throws {
        let settings = LeonardSettings()
        let frames: [OutgoingFrame] = [
            .hello(HelloFrame(ts: 1, locale: "it")),
            .settings(settings.daemonFrame()),
            .memoryObserve(MemoryObserveFrame(ts: 1_790_000_000, app: "Safari", bundleId: "com.apple.Safari",
                                              window: "Docs", text: "Installation guide for the product, step one")),
            .event(EventFrame(ts: 1_790_000_000, id: "evt_app_fixture", kind: .mailOpened, app: "Mail",
                              payload: EventPayload(typing: false, idle: false, fields: [
                                  "sender": .string("Marco Rossi <marco@studiorossi.it>"),
                                  "subject": .string("Preventivo"),
                                  "body": .string("Ciao, mi confermi il preventivo?"),
                                  "thread_len": .number(1), "unread": .bool(true),
                              ]))),
            .ask(AskFrame(id: "ask_app", prompt: "Cosa dice la guida?", mode: .ask)),
            .cancel(CancelFrame(requestId: "ask_app")),
            .memorySearch(MemorySearchFrame(id: "s1", query: "guide")),
            .memoryRecent(MemoryRecentFrame(id: "r1")),
            .memoryStats(RequestFrame(id: "ms1")),
            .stats(RequestFrame(id: "st1")),
            .learningMute(LearningMuteFrame(id: "lm1", sender: "news@example.com")),
            .learningForget(LearningForgetFrame(id: "lf1", ruleId: "sender:news@example.com")),
            .dismiss(DecisionResponseFrame(ts: 1, decisionId: "dec_unknown", reason: .timeout)),
            .memoryDelete(MemoryDeleteFrame(id: "d1", scope: .query, query: "guide")),
            .reload(RequestFrame(id: "rl1")),
        ]
        let lines = try frames.map { String(decoding: try $0.encoded(), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(
            to: Self.fixtures.appendingPathComponent("app_frames.jsonl"), atomically: true, encoding: .utf8
        )
        let settingsLine = lines[1]
        #expect(settingsLine.contains("\"quiet_hours\":null"))
        #expect(lines[12].contains("\"reason\":\"timeout\""))
    }
}
