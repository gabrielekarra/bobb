import SwiftUI
import BobbCore

/// Read-only browser over the daemon's audit store: what Bobb noticed,
/// what it decided, why, and what the user did about it. Opens
/// `AuditStore` itself (read-only, alongside the daemon's live WAL
/// database) and polls rather than pushing, since nothing here needs
/// sub-second freshness.
struct AuditView: View {
    @Bindable var viewModel: AuditViewModel

    init(auditPath: String) {
        self.viewModel = AuditViewModel(auditPath: auditPath)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField(L10n.t(.auditSearch), text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                Divider()
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    List(viewModel.records, selection: $viewModel.selectedID) { record in
                        AuditRowView(record: record).tag(record.id)
                    }
                    .listStyle(.inset)
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            if let selectedRecord = viewModel.selectedRecord {
                AuditDetailView(record: selectedRecord)
            } else {
                Text(L10n.t(.auditSelect))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await viewModel.openAndPoll() }
        .onChange(of: viewModel.searchText) { _, _ in viewModel.load() }
    }
}

private struct AuditRowView: View {
    let record: AuditRecord

    var body: some View {
        HStack(spacing: 8) {
            Text(badgeText)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(badgeColor, in: Capsule())
            VStack(alignment: .leading, spacing: 1) {
                Text("\(record.kind) · \(record.app ?? "—")")
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Text(Self.timeFormatter.string(from: Date(timeIntervalSince1970: record.ts)))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let response = record.response {
                Text(response == "approve" ? "✓" : "✕")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(response == "approve" ? .green : .secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var badgeText: String {
        record.abstained ? "ABSTAIN" : record.action.rawValue.uppercased()
    }

    private var badgeColor: Color {
        if record.abstained { return .red }
        switch record.action {
        case .ignore, .wait: return .gray
        case .prepare: return .blue
        case .suggest: return .orange
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct AuditDetailView: View {
    let record: AuditRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !record.hypotheses.isEmpty {
                    section(L10n.t(.mindHypotheses)) {
                        ForEach(record.hypotheses, id: \.intent) { hypothesis in
                            HStack {
                                Text(hypothesis.intent).font(.system(size: 11.5))
                                Spacer()
                                Text(String(format: "%.2f", hypothesis.p))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !record.readouts.isEmpty {
                    section(L10n.t(.mindReadouts)) {
                        ForEach(record.readouts, id: \.q) { readout in
                            ReadoutBarView(readout: readout)
                        }
                    }
                }
                if let suggestion = record.suggestion {
                    section(L10n.t(.menuForYou)) {
                        Text(suggestion.title).font(.system(size: 12, weight: .medium))
                        Text(suggestion.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                section(L10n.t(.auditRawEvent)) {
                    Text(payloadDescription)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(record.kind) · \(record.app ?? "app sconosciuta")")
                .font(.system(size: 15, weight: .semibold))
            Text(record.why ?? "")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                metric("azione", record.action.rawValue)
                metric("confidenza", String(format: "%.2f", record.confidence))
                metric("massa", String(format: "%.2f", record.schemaMass))
                metric("soglia", String(format: "%.2f", record.floor))
                metric("latenza", String(format: "%.0f ms", record.latencyMs))
            }
            if let response = record.response {
                Text("Risposta dell'utente: \(response == "approve" ? "ha preparato" : "ha ignorato")")
                    .font(.system(size: 11))
                    .foregroundStyle(response == "approve" ? .green : .secondary)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced))
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var payloadDescription: String {
        guard case .object(let fields) = record.eventPayload, !fields.isEmpty else { return "—" }
        return fields.sorted(by: { $0.key < $1.key })
            .map { key, value in "\(key): \(describe(value))" }
            .joined(separator: "\n")
    }

    private func describe(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): s
        case .number(let n): n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
        case .bool(let b): b ? "true" : "false"
        case .null: "—"
        case .array: "[…]"
        case .object: "{…}"
        }
    }
}
