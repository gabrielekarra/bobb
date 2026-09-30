import SwiftUI
import BobbCore

/// One event's full life, per the product's central claim: silence is
/// invisible unless shown. An abstained decision — a near-miss that stayed
/// silent — gets a red badge, a tinted background and its own callout,
/// deliberately louder than an ordinary `ignore`, because that near-miss is
/// the proof the system works.
struct MindEntryRow: View {
    let entry: MindEntry
    let floor: Double
    let uiState: MindUIState

    private var decision: DecisionFrame? { entry.decision }
    private var isAbstained: Bool { decision?.abstained == true }
    private var expanded: Bool { uiState.isExpanded(entry.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(12)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { uiState.toggle(entry.id) } }

            if expanded {
                details
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isAbstained ? 1.5 : 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            actionBadge
            VStack(alignment: .leading, spacing: 1) {
                Text("\(entry.event.kind.rawValue) · \(entry.event.app)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(decision.map { $0.explanation ?? $0.why } ?? L10n.t(.mindWaiting))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let decision {
                if decision.decidedBySpecialist {
                    Pill(text: L10n.t(.mindSpecialistBadge), color: .green)
                }
                Text(decision.latencyMs < 10 ? String(format: "%.1f ms", decision.latencyMs) : String(format: "%.0f ms", decision.latencyMs))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.mini)
            }
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var actionBadge: some View {
        Text(badgeText)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor, in: Capsule())
    }

    private var badgeText: String {
        guard let decision else { return "…" }
        if decision.abstained { return "ABSTAIN" }
        return switch decision.action {
        case .ignore: "IGNORE"
        case .wait: "WAIT"
        case .prepare: "PREPARE"
        case .suggest: "SUGGEST"
        }
    }

    private var badgeColor: Color {
        guard let decision else { return .gray }
        if decision.abstained { return .red }
        return switch decision.action {
        case .ignore, .wait: .gray
        case .prepare: .blue
        case .suggest: .orange
        }
    }

    private var borderColor: Color {
        isAbstained ? Color.red.opacity(0.55) : Color.primary.opacity(0.08)
    }

    private var background: AnyShapeStyle {
        isAbstained ? AnyShapeStyle(Color.red.opacity(0.07)) : AnyShapeStyle(Color.primary.opacity(0.03))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isAbstained, let decision {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 11))
                    Text(L10n.t(.mindNearMiss, ["confidence": L10n.percent(decision.confidence), "floor": L10n.percent(decision.floor ?? floor)]))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.primary)
                }
                .padding(8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            if !payloadFields.isEmpty {
                sectionLabel(L10n.t(.mindEvent))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(payloadFields, id: \.0) { key, value in
                        HStack(spacing: 4) {
                            Text(key).foregroundStyle(.secondary)
                            Text(value).lineLimit(1)
                        }
                        .font(.system(size: 10.5, design: .monospaced))
                    }
                }
            }

            if !entry.traces.isEmpty {
                sectionLabel("Trace")
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(entry.traces.enumerated()), id: \.offset) { _, trace in
                        HStack {
                            Text(trace.rawStage)
                                .font(.system(size: 10.5, weight: .medium))
                            Text(trace.detail)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "%.2f ms", trace.ms))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let decision, !decision.hypotheses.isEmpty {
                sectionLabel(L10n.t(.mindHypotheses))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(decision.hypotheses, id: \.intent) { hypothesis in
                        HStack(spacing: 6) {
                            Text(hypothesis.intent)
                                .font(.system(size: 10.5))
                                .frame(width: 140, alignment: .leading)
                                .lineLimit(1)
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.accentColor.opacity(0.7))
                                    .frame(width: max(2, proxy.size.width * hypothesis.p))
                            }
                            .frame(height: 5)
                            Text(String(format: "%.2f", hypothesis.p))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let decision, !decision.readouts.isEmpty {
                sectionLabel(L10n.t(.mindReadouts))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(decision.readouts, id: \.q) { readout in
                        ReadoutBarView(readout: readout)
                    }
                }
            }

            if let decision, let suggestion = decision.suggestion {
                sectionLabel(L10n.t(.menuForYou))
                Text(suggestion.title)
                    .font(.system(size: 10.5, weight: .medium))
                Text(suggestion.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if let decision, !decision.why.isEmpty {
                sectionLabel(L10n.t(.mindTechnical))
                Text(decision.why)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var payloadFields: [(String, String)] {
        entry.event.payload.fields
            .sorted(by: { $0.key < $1.key })
            .prefix(6)
            .map { key, value in (key, summarize(value)) }
    }

    private func summarize(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): s.count > 60 ? String(s.prefix(60)) + "…" : s
        case .number(let n): n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
        case .bool(let b): b ? "true" : "false"
        case .null: "—"
        case .array: "[…]"
        case .object: "{…}"
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
    }
}
