import Charts
import SwiftUI
import BobbCore

/// Confidence of every recent decision against the live floor. Color is
/// computed from `floor` at render time, not from the historical
/// `action`/`abstained` the daemon attached — so dragging the slider
/// visibly repaints what would surface, which is the entire point of the
/// panel. Abstained decisions get their own color and a larger mark
/// (prominent, not hidden) rather than blending into "stayed silent."
struct ConfidenceFloorChart: View {
    let entries: [MindEntry]
    let floor: Double

    private struct Point: Identifiable {
        let id: String
        let index: Int
        let confidence: Double
        let wouldSurface: Bool
        let abstained: Bool
    }

    private var points: [Point] {
        let chronological = entries.compactMap(\.decision).reversed()
        return chronological.suffix(80).enumerated().map { offset, decision in
            Point(
                id: decision.id, index: offset, confidence: decision.confidence,
                wouldSurface: decision.confidence >= floor, abstained: decision.abstained
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.t(.chartTitle))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                legend
            }

            if points.isEmpty {
                Text(L10n.t(.mindEmpty))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                Chart {
                    RuleMark(y: .value("Threshold", floor))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text(L10n.t(.chartThreshold, ["value": String(format: "%.2f", floor)]))
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                    ForEach(points) { point in
                        PointMark(
                            x: .value("Decisione", point.index),
                            y: .value("Confidenza", point.confidence)
                        )
                        .foregroundStyle(color(for: point))
                        .symbolSize(point.abstained ? 100 : 32)
                    }
                }
                .chartYScale(domain: 0...1)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 0.25, 0.5, 0.75, 1.0])
                }
                .frame(height: 120)
            }
        }
    }

    private func color(for point: Point) -> Color {
        if point.abstained { return .red }
        return point.wouldSurface ? Theme.accent : .secondary.opacity(0.45)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendItem(color: Theme.accent, label: L10n.t(.chartWouldSurface))
            legendItem(color: .secondary.opacity(0.45), label: L10n.t(.chartSilent))
            legendItem(color: .red, label: L10n.t(.chartNearMiss))
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }
}
