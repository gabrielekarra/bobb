import Foundation
import BobbCore

/// Explicitly selected folders, independently opted into local memory.
/// Polling is bounded and extraction happens off the UI thread.
@MainActor
final class FolderMemorySensor {
    var settings: () -> BobbSettings = { BobbSettings() }
    var onMemory: ((MemoryObserveFrame) -> Void)?
    private var timer: Timer?
    private var job: Task<Void, Never>?
    private var generation = UUID()
    private var remembered: [String: String] = [:]
    private func allowed(_ s: BobbSettings) -> Bool {
        s.watching && s.memoryEnabled && s.bobb.boundaries.app(bundleId: "com.apple.finder", name: "Finder") != nil
            && !ScreenMemoryPolicy(extraProtected: s.extraProtectedApps).isProtected(bundleId: "com.apple.finder", appName: "Finder")
    }
    func configure() {
        let s = settings()
        guard allowed(s), (s.bobb.fileFolders ?? []).contains(where: \.indexEnabled) else { stop(); return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }
        tick()
    }
    func stop() { generation = UUID(); timer?.invalidate(); timer = nil; job?.cancel(); job = nil }
    private func tick() {
        guard job == nil, allowed(settings()) else { return }
        let selected = (settings().bobb.fileFolders ?? []).filter(\.indexEnabled)
        let known = remembered
        let generation = generation
        job = Task { [weak self] in
            let scan = Task.detached(priority: .utility) { () -> [(FileFolder, URL, String, String, String)] in
                var results: [(FileFolder, URL, String, String, String)] = []
                for folder in selected {
                    guard !Task.isCancelled, let root = try? FileAppTools.root(folder) else { continue }
                    let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }
                    guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                    var count = 0
                    let started = Date()
                    for case let url as URL in iterator {
                        count += 1; if count > 2000 || results.count >= 100 || Date().timeIntervalSince(started) > 3 || Task.isCancelled { break }
                        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 2_000_000,
                              let relative = url.path.hasPrefix(root.path + "/") ? String(url.path.dropFirst(root.path.count + 1)) : nil,
                              let safe = FileScope.resolve(relative, root: root), safe == url.resolvingSymlinksInPath() else { continue }
                        let key = folder.id + ":" + relative
                        let signature = "\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                        guard known[key] != signature, let text = try? FileAppTools.text(safe), !text.isEmpty else { continue }
                        results.append((folder, url, key, signature, String(text.prefix(8000))))
                    }
                }
                return results
            }
            let results = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard let self, self.generation == generation else { return }; defer { self.job = nil }
            for (folder, url, key, digest, text) in results {
                guard !Task.isCancelled, self.allowed(self.settings()), self.settings().bobb.fileFolders?.contains(folder) == true else { break }
                self.remembered[key] = digest
                self.onMemory?(MemoryObserveFrame(ts: Date().timeIntervalSince1970, app: "Finder", bundleId: "com.apple.finder", window: folder.name + "/" + url.lastPathComponent,
                    text: "File: \(url.lastPathComponent)\nContent excerpt (up to 8000 characters):\n" + text, url: url.absoluteString, source: "file"))
            }
            if self.remembered.count > 5000 { self.remembered.removeAll() }
        }
    }
}
