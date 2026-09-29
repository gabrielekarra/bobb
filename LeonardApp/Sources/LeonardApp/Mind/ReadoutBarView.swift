import SwiftUI
import LeonardCore

/// One readout's full distribution as a thin 100%-stacked bar: the chosen
/// answer's segment is filled in the accent color, every other option is a
/// recessive gray, with a 2px gap between segments. A 0.51/0.49 split and a
/// 0.95/0.05 split carry the same headline `p` for the winner and look
/// nothing alike here — that is the point.
struct ReadoutBarView: View {
    let readout: Readout

    private var ordered: [(label: String, p: Double)] { readout.orderedProbabilities }

    private var chosenLabel: String {
        switch readout.value {
        case .bool(let value): value ? "true" : "false"
        case .number(let value): String(Int(value.rounded()))
        case .string(let value): value
        default: ""
        }
    }

    private var runnerUp: (label: String, p: Double)? {
        let others = ordered.filter { $0.label != chosenLabel }
        guard let top = others.max(by: { $0.p < $1.p }) else { return nil }
        let winnerP = ordered.first(where: { $0.label == chosenLabel })?.p ?? readout.p
        return (winnerP - top.p) < 0.15 ? top : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(readout.q)
                    .font(.system(size: 10.5, weight: .medium))
                Spacer()
                Text(chosenLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text(String(format: "p %.2f", readout.p))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(L10n.t(.readoutMass, ["value": String(format: "%.2f", readout.schemaMass)]))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(readout.schemaMass < 0.5 ? Color.red : .secondary)
            }

            if ordered.isEmpty {
                Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 5)
            } else {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(ordered, id: \.label) { entry in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(entry.label == chosenLabel ? Color.accentColor : Color.secondary.opacity(0.22))
                                .frame(width: max(3, proxy.size.width * entry.p))
                        }
                    }
                }
                .frame(height: 5)
            }

            if let runnerUp {
                Text(L10n.t(.readoutCloseTo, ["label": runnerUp.label, "p": String(format: "%.2f", runnerUp.p)]))
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
    }
}
