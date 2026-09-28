import AppKit
import Observation
import SwiftUI
import LeonardCore

@MainActor
@Observable
final class MemoryBrowserModel {
    var query = ""
    var app: String?
    var results: [MemoryHit] = []
    var stats: MemoryStatsFrame?
    var loading = false
    var message: String?
    var confirmDeleteAll = false
    private var searchTask: Task<Void, Never>?

    func refresh(using coordinator: LeonardCoordinator, debounce: Bool = false) {
        searchTask?.cancel()
        let query = self.query
        let app = self.app
        searchTask = Task {
            if debounce { try? await Task.sleep(nanoseconds: 250_000_000) }
            if Task.isCancelled { return }
            loading = true
            let found = await coordinator.searchMemory(query, app: app)
            let counted = await coordinator.memoryStats()
            if Task.isCancelled { return }
            self.results = found?.results ?? []
            if let counted { self.stats = counted }
            loading = false
        }
    }

    func delete(_ frame: MemoryDeleteFrame, using coordinator: LeonardCoordinator) {
        Task {
            if let count = await coordinator.deleteMemory(frame) {
                message = L10n.t(.memoryDeleted, ["count": "\(count)"])
            }
            refresh(using: coordinator)
        }
    }
}

/// Everything Leonard remembers, readable and deletable by the person it is
/// about. A memory you cannot inspect is a memory you cannot trust
/// (`docs/SCREEN-MEMORY.md`), so this window is not a setting buried three
/// levels deep: it is one click from the menu bar.
struct MemoryView: View {
    @Bindable var state: AppState
    @Bindable var model: MemoryBrowserModel
    let coordinator: LeonardCoordinator

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
            main.frame(minWidth: 460)
        }
        .frame(minWidth: 760, minHeight: 480)
        .tint(Theme.accent)
        .onAppear { model.refresh(using: coordinator) }
        .confirmationDialog(L10n.t(.memoryDeleteAllConfirm), isPresented: $model.confirmDeleteAll) {
            Button(L10n.t(.genericDelete), role: .destructive) {
                model.delete(MemoryDeleteFrame(id: RequestFrame.newID(), scope: .all), using: coordinator)
            }
            Button(L10n.t(.genericCancel), role: .cancel) {}
        } message: {
            Text(L10n.t(.memoryDeleteAllBody))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let stats = model.stats {
                Text(L10n.t(.memoryRows, ["count": "\(stats.rows)"]))
                    .font(.system(size: 13, weight: .semibold))
                if let bytes = stats.bytes {
                    Text(ModelInstallation.formatBytes(Int64(bytes)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Theme.sectionTitle(L10n.t(.memoryApps))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    appRow(nil, label: L10n.t(.memoryRecent), count: model.stats?.rows)
                    ForEach(model.stats?.apps ?? []) { app in
                        appRow(app.app, label: app.app, count: app.rows)
                    }
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Button(L10n.t(.memoryDeleteLastHour)) {
                    model.delete(MemoryDeleteFrame(id: RequestFrame.newID(), scope: .range, since: Date().timeIntervalSince1970 - 3600), using: coordinator)
                }
                Button(L10n.t(.memoryDeleteToday)) {
                    let midnight = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
                    model.delete(MemoryDeleteFrame(id: RequestFrame.newID(), scope: .range, since: midnight), using: coordinator)
                }
                Button(L10n.t(.memoryDeleteAll), role: .destructive) { model.confirmDeleteAll = true }
            }
            .buttonStyle(.link)
            .font(.system(size: 11.5))
        }
        .padding(14)
        .background(Color.primary.opacity(0.02))
    }

    private func appRow(_ app: String?, label: String, count: Int?) -> some View {
        Button {
            model.app = app
            model.refresh(using: coordinator)
        } label: {
            HStack {
                Text(label).lineLimit(1)
                Spacer()
                if let count { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(model.app == app ? Theme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.t(.memorySearch), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onChange(of: model.query) { _, _ in model.refresh(using: coordinator, debounce: true) }
                if model.loading { ProgressView().controlSize(.small) }
            }
            .padding(12)
            Divider()
            if !state.settings.memoryEnabled {
                Label(L10n.t(.memoryPaused), systemImage: "pause.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.attention)
                    .padding(10)
            }
            if model.results.isEmpty && !model.loading {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(L10n.t(.memoryEmpty)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.results) { hit in
                    row(hit)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Image(systemName: "lock.fill").font(.system(size: 9))
                Text(model.message ?? L10n.t(.memoryPrivacyNote))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .padding(10)
        }
    }

    private func row(_ hit: MemoryHit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(hit.app).font(.system(size: 11.5, weight: .semibold))
                    if !hit.window.isEmpty {
                        Text(hit.window).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(L10n.relative(hit.lastSeen)).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                Text(hit.snippet)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            Menu {
                Button(L10n.t(.memoryDelete), role: .destructive) {
                    model.delete(MemoryDeleteFrame(id: RequestFrame.newID(), scope: .row, rowId: hit.id), using: coordinator)
                }
                Button(L10n.t(.memoryDeleteApp, ["app": hit.app]), role: .destructive) {
                    model.delete(MemoryDeleteFrame(id: RequestFrame.newID(), scope: .app, app: hit.app), using: coordinator)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }
}
