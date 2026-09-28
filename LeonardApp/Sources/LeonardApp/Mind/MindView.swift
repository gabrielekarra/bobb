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
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                connectionSection
                tallySection
                ConfidenceFloorChart(entries: state.entries, floor: state.floor)
                floorSection
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
            Toggle("Osserva", isOn: $state.watching)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 11))
        }
    }

    private var connectionText: String {
        switch state.connection {
        case .disconnected: "Disconnesso"
        case .connecting: "Connessione…"
        case .connected: "Handshake…"
        case .ready(let ready): "Connesso · \(ready.model)"
        case .reconnecting(let attempt, _): "Riconnessione (tentativo \(attempt))"
        }
    }

    private var connectionColor: Color {
        state.connection.isReady ? .green : .secondary
    }

    private var tallySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Bilancio")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                statTile("Eventi", "\(state.eventsSeen)")
                statTile("Decisioni", "\(state.decisionsMade)")
                statTile("Silenzi", "\(state.staySilentCount)")
                statTile("Latenza mediana", String(format: "%.0f ms", state.medianDecisionLatencyMs))
            }
            if state.decisionsMade > 0 {
                let percentSilent = Double(state.staySilentCount) / Double(state.decisionsMade) * 100
                Text(String(format: "%.0f%% delle decisioni sono rimaste in silenzio", percentSilent))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if state.learningSignalCount > 0 {
                Text("\(state.learningSignalCount) eventi di apprendimento (mail arrivata/chiusa/archiviata/eliminata) nel conteggio, esclusi dall'elenco qui accanto")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
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
                sectionTitle("Soglia di interruzione")
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
            Text("Muovi la soglia: il grafico sopra ridisegna subito cosa emergerebbe.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var filterSection: some View {
        Toggle("Nascondi eventi di apprendimento", isOn: $state.hideLearningSignalsInMind)
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
                    Text("Nessun evento ancora. Leonard sta osservando.")
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
