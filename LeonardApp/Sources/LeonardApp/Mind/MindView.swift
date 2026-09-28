import SwiftUI
import LeonardCore

/// Leonard's central differentiator: the live perception-and-decision
/// stream. The product's claim is that it chooses silence well, and
/// silence is invisible unless shown — so this view exists to show it.
struct MindView: View {
    @Bindable var state: AppState
    let coordinator: LeonardCoordinator
    var uiState = MindUIState()

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 270, idealWidth: 300, maxWidth: 360)
            entryList
                .frame(minWidth: 420)
        }
        .frame(minWidth: 760, minHeight: 460)
        .tint(Theme.accent)
        .task { await coordinator.refreshStats() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                connectionSection
                tallySection
                ConfidenceFloorChart(entries: state.entries, floor: state.floor)
                floorSection
                learnedSection
                filterSection
            }
            .padding(16)
        }
        .background(Color.primary.opacity(0.02))
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(connectionColor).frame(width: 7, height: 7)
                Text(connectionText)
                    .font(.system(size: 11.5, weight: .medium))
            }
            Toggle(L10n.t(.mindWatch), isOn: Binding(get: { state.watching }, set: { coordinator.setWatching($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 11))
        }
    }

    private var connectionText: String {
        switch state.connection {
        case .ready(let ready): L10n.t(.mindConnected, ["model": ready.model.components(separatedBy: "/").last ?? ready.model])
        case .connected, .connecting, .reconnecting: L10n.t(.statusStarting)
        case .disconnected: L10n.t(.statusDisconnected)
        }
    }

    private var connectionColor: Color {
        state.connection.isReady ? .green : .secondary
    }

    private var tallySection: some View {
        let summary = state.stats?.decisions ?? DecisionSummary(
            decisions: state.decisionsMade, suggested: state.decisionsMade - state.staySilentCount,
            silent: state.staySilentCount
        )
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.t(.mindToday))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                statTile(L10n.t(.mindDecisions), "\(summary.decisions)")
                statTile(L10n.t(.mindSilences), "\(summary.silent)")
                statTile(L10n.t(.mindAccepted), summary.acceptance.map { L10n.percent($0) } ?? "—")
                statTile(L10n.t(.mindLatency), state.medianDecisionLatencyMs > 0 ? String(format: "%.0f ms", state.medianDecisionLatencyMs) : "—")
            }
            if summary.decisions > 0 {
                Text(L10n.t(.mindSilentShare, ["percent": L10n.percent(Double(summary.silent) / Double(summary.decisions))]))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var learnedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.t(.mindLearned))
            let learning = state.stats?.learning
            let kinds = (learning?.kinds ?? []).filter { $0.learning }
            let muted = learning?.mutedSenders ?? []
            if kinds.isEmpty && muted.isEmpty {
                Text(L10n.t(.mindLearnedEmpty))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(kinds) { kind in
                Text(L10n.t(.mindPersonalFloor, [
                    "kind": kind.kind, "floor": L10n.percent(kind.floor),
                    "approved": "\(kind.approved)", "dismissed": "\(kind.dismissed)",
                ]))
                .font(.system(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(muted) { rule in
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(L10n.t(.mindMutedSender, ["sender": rule.sender]))
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                    Spacer()
                    Button(L10n.t(.mindForget)) { coordinator.forget(ruleId: rule.ruleId) }
                        .buttonStyle(.link)
                        .font(.system(size: 10.5))
                }
            }
        }
    }

    private func statTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var floorSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionTitle(L10n.t(.mindFloor))
                Spacer()
                Text(String(format: "%.2f", state.floor))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            Slider(
                value: Binding(get: { state.floor }, set: { state.floor = $0 }),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing { coordinator.setFloor(state.floor) }
                }
            )
            .controlSize(.small)
            Text(L10n.t(.mindFloorHint))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var filterSection: some View {
        Toggle(L10n.t(.mindHideSignals), isOn: $state.hideLearningSignalsInMind)
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
    }

    // MARK: Entry list

    private var entryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if state.visibleEntries.isEmpty {
                    Text(L10n.t(.mindEmpty))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
                } else {
                    ForEach(state.visibleEntries) { entry in
                        MindEntryRow(entry: entry, floor: state.floor, uiState: uiState)
                    }
                }
            }
            .padding(16)
        }
    }
}
