import Foundation

/// Picks, from everything the accessibility tree offers, the few elements
/// worth showing the model for this step — the `jev-ultrafast` principle of
/// an indexed element table narrowed before scoring, so the readout stays a
/// short list read in one pass.
///
/// Ranking is lexical and structural, no model: words shared with the
/// request and the plan, the focused field, what is visible, what is
/// enabled. Menu items (there are hundreds) are offered only when their
/// words match. Duplicates that read the same are collapsed.
public struct CandidateRanker: Sendable {
    public struct Limits: Sendable {
        public var press: Int
        public var text: Int
        public var scroll: Int

        public init(press: Int = 22, text: Int = 8, scroll: Int = 4) {
            self.press = press
            self.text = text
            self.scroll = scroll
        }

        func limit(_ kind: CandidateKind) -> Int {
            switch kind {
            case .press: press
            case .text: text
            case .scroll: scroll
            }
        }
    }

    public struct Ranked: Sendable, Equatable {
        public var element: UIElementSnapshot
        public var kind: CandidateKind
        public var label: String
        public var score: Double
    }

    public var limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Ranked candidates per kind, best first. `screen` is the visible area;
    /// elements outside it are demoted, not dropped (a list may scroll).
    public func rank(_ elements: [UIElementSnapshot], goal: String, focus: String = "", recent: [String] = [],
                     screen: ScreenRect? = nil) -> [CandidateKind: [Ranked]] {
        let goalWords = Set(Tokens.words(goal))
        let focusWords = Set(Tokens.words(focus))
        let recentLabels = Set(recent.map { $0.lowercased() })

        var best: [String: Ranked] = [:]
        for element in elements {
            guard let kind = ElementClassifier.kind(of: element) else { continue }
            let label = ElementClassifier.label(of: element)
            // An unlabelled button is unusable by name; a field can still be
            // described by being focused.
            if label.isEmpty && !(kind == .text && element.focused) && kind != .scroll { continue }
            var score = baseScore(kind, element)
            let words = Tokens.words(label + " " + element.value.prefix(60))
            let lexical = overlap(words, goalWords) * 3 + overlap(words, focusWords) * 4
            score += lexical
            if element.isMenuItem && lexical == 0 { continue }
            if element.focused { score += kind == .text ? 5 : 1 }
            if !element.enabled { score -= 4 }
            if element.selected { score += 0.3 }
            if let frame = element.frame {
                if frame.isEmpty { score -= 3 }
                if let screen, !frame.intersects(screen) { score -= 2 }
            } else if !element.isMenuItem {
                score -= 0.5
            }
            if recentLabels.contains(label.lowercased()) { score -= 0.5 }
            let shownLabel = label.isEmpty ? ElementClassifier.roleName(element) : label
            let ranked = Ranked(element: element, kind: kind, label: shownLabel, score: score)
            let dedupe = "\(kind.rawValue)|\(shownLabel.lowercased())|\(ElementClassifier.place(of: element).lowercased())"
            if let existing = best[dedupe], existing.score >= score { continue }
            best[dedupe] = ranked
        }

        var out: [CandidateKind: [Ranked]] = [:]
        for kind in CandidateKind.allCases {
            let sorted = best.values.filter { $0.kind == kind }.sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                // Reading order for ties: top to bottom, left to right.
                let l = lhs.element.frame, r = rhs.element.frame
                if let l, let r {
                    if abs(l.y - r.y) > 4 { return l.y < r.y }
                    return l.x < r.x
                }
                return lhs.element.key < rhs.element.key
            }
            out[kind] = Array(sorted.prefix(limits.limit(kind)))
        }
        return out
    }

    func baseScore(_ kind: CandidateKind, _ element: UIElementSnapshot) -> Double {
        switch kind {
        case .text: 2
        case .scroll: 0.5
        case .press:
            switch element.role {
            case "AXButton", "AXLink", "AXTab", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox": 1
            case "AXMenuItem": -0.5
            default: 0.3
            }
        }
    }

    func overlap(_ words: [String], _ reference: Set<String>) -> Double {
        guard !reference.isEmpty, !words.isEmpty else { return 0 }
        var score = 0.0
        for word in Set(words) {
            if reference.contains(word) {
                score += 1
            } else if word.count >= 4, reference.contains(where: { $0.count >= 4 && ($0.hasPrefix(word) || word.hasPrefix($0)) }) {
                score += 0.5
            }
        }
        return score
    }
}

/// The offered ids for one observation, and the way back to the element
/// each one names. Ids are opaque and fresh per observation, so a verdict
/// can only ever name something that was on screen when it was asked.
public struct CandidateTable: Sendable {
    public private(set) var candidates: [AgentCandidate] = []
    public private(set) var keys: [String: Int] = [:]
    public private(set) var byId: [String: UIElementSnapshot] = [:]

    public init(ranked: [CandidateKind: [CandidateRanker.Ranked]], observation: Int) {
        var index = 0
        for kind in CandidateKind.allCases {
            for item in ranked[kind] ?? [] {
                index += 1
                let id = "o\(observation)e\(index)"
                let element = item.element
                candidates.append(
                    AgentCandidate(
                        id: id,
                        label: item.label,
                        role: ElementClassifier.roleName(element),
                        kind: kind,
                        enabled: element.enabled,
                        focused: element.focused,
                        value: kind == .text ? String(element.value.prefix(200)) : "",
                        where: ElementClassifier.place(of: element)
                    )
                )
                keys[id] = element.key
                byId[id] = element
            }
        }
    }

    /// A short fingerprint of what was offered, so the daemon can tell a
    /// step that changed nothing from one that did.
    public var digest: String {
        var hash: UInt64 = 1469598103934665603
        for c in candidates {
            for byte in "\(c.kind.rawValue)|\(c.label)|\(c.value)|\(c.focused)\n".utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1099511628211
            }
        }
        return String(hash, radix: 16)
    }
}
