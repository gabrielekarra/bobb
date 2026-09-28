import SwiftUI
import LeonardCore

/// The popover shown on a click of the menu bar item — Leonard's front
/// door. Leads with status and, when there is one, the live suggestion;
/// falls back to a short recent-activity list so the panel is never just
/// an empty status line.
struct MenuBarPopoverView: View {
    @Bindable var state: AppState
    let onPrepare: () -> Void
    let onDismiss: () -> Void
    let onFloorChanged: (Double) -> Void
    let openMind: () -> Void
    let openAudit: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let suggestion = state.activeSuggestion?.suggestion {
                suggestionCard(suggestion)
                Divider()
            } else {
                recentActivity
                Divider()
            }

            floorControl
            Divider()
            footer
        }
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(connectionSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $state.watching)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func suggestionCard(_ suggestion: Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(suggestion.title)
                .font(.system(size: 12.5, weight: .medium))
            if !suggestion.detail.isEmpty {
                Text(suggestion.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Ignora", action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11.5))
                Button("Prepara", action: onPrepare)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(14)
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.visibleEntries.isEmpty {
                Text("Nessuna attività ancora")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.visibleEntries.prefix(4)) { entry in
                    HStack(spacing: 6) {
                        Text(badge(for: entry))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(badgeColor(for: entry), in: Capsule())
                        Text(entry.event.kind.rawValue)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var floorControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Soglia di interruzione")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f", state.floor))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { state.floor },
                    set: { state.floor = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing { onFloorChanged(state.floor) }
                }
            )
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            footerButton("Mind", action: openMind)
            footerButton("Audit", action: openAudit)
            Spacer()
            footerButton("Esci", action: quit)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }

    private var statusTitle: String {
        switch state.activityState {
        case .disconnected: "Leonard non è connesso"
        case .watching: state.watching ? "Sto osservando" : "In pausa"
        case .thinking: "Sto pensando…"
        case .suggesting: "Ho un suggerimento"
        }
    }

    private var connectionSubtitle: String {
        switch state.connection {
        case .disconnected: "leonardd non è raggiungibile"
        case .connecting: "connessione in corso…"
        case .connected: "handshake in corso…"
        case .ready(let ready): ready.model
        case .reconnecting(let attempt, _): "riconnessione, tentativo \(attempt)"
        }
    }

    private var dotColor: Color {
        switch state.activityState {
        case .disconnected: .secondary
        case .watching: .primary
        case .thinking: .blue
        case .suggesting: .orange
        }
    }

    private func badge(for entry: MindEntry) -> String {
        guard let action = entry.decision?.action else { return "…" }
        return switch action {
        case .ignore: "IGN"
        case .wait: "WAIT"
        case .prepare: "PREP"
        case .suggest: "SUGG"
        }
    }

    private func badgeColor(for entry: MindEntry) -> Color {
        guard let decision = entry.decision else { return .gray }
        if decision.abstained { return .yellow }
        return switch decision.action {
        case .ignore: .gray
        case .wait: .gray
        case .prepare: .blue
        case .suggest: .orange
        }
    }
}
