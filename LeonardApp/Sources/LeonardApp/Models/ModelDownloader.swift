import CryptoKit
import Foundation
import Observation
import LeonardCore

/// The one network operation in the product: downloading the model, once,
/// when the user presses the button. Every file is fetched from the pinned
/// revision into a staging directory, checked against its published SHA-256
/// and only then moved into place, so a half-finished or tampered download
/// is never loaded. `leonardd` itself has no network access at all.
@MainActor
@Observable
final class ModelDownloader {
    enum Phase: Equatable {
        case idle
        case downloading(fraction: Double, received: Int64, total: Int64)
        case verifying(fraction: Double)
        case installed
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    let manifest: ModelManifest
    let modelsDirectory: URL

    private var task: Task<Void, Never>?
    private let session: URLSession

    init(manifest: ModelManifest = .default, modelsDirectory: URL) {
        self.manifest = manifest
        self.modelsDirectory = modelsDirectory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 3600
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
        if ModelInstallation.isInstalled(manifest, in: modelsDirectory) {
            phase = .installed
        }
    }

    var isInstalled: Bool { ModelInstallation.isInstalled(manifest, in: modelsDirectory) }
    var installDirectory: URL { ModelInstallation.directory(for: manifest, in: modelsDirectory) }
    private var stagingDirectory: URL {
        modelsDirectory.appendingPathComponent(".download-\(manifest.directoryName)", isDirectory: true)
    }

    func start(onInstalled: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        if isInstalled {
            phase = .installed
            onInstalled()
            return
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.download()
                try await self.verifyStaged()
                try self.install()
                self.phase = .installed
                onInstalled()
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                self.phase = .failed(Self.describe(error))
            }
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Hash every installed file against the manifest. Returns the names of
    /// files that do not match.
    func verifyInstalled(progress: @escaping @MainActor (Double) -> Void) async -> [String] {
        await Self.mismatches(manifest.files, in: installDirectory, progress: progress)
    }

    // MARK: Steps

    private func download() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let total = manifest.totalBytes
        var completed: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            let destination = stagingDirectory.appendingPathComponent(file.name)
            if let size = (try? fm.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber, size.int64Value == file.size {
                completed += file.size
                continue
            }
            let base = completed
            phase = .downloading(fraction: Double(base) / Double(total), received: base, total: total)
            let temporary = try await fetch(manifest.url(for: file)) { [weak self] received in
                guard let self else { return }
                let now = base + received
                self.phase = .downloading(fraction: Double(now) / Double(total), received: now, total: total)
            }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: temporary, to: destination)
            completed += file.size
        }
    }

    /// Downloads one file. A dropped connection is retried with backoff and,
    /// when the server allows it, resumed from the bytes already received, so
    /// a hiccup at 1.5 GB does not start the model over.
    private func fetch(_ url: URL, progress: @escaping @MainActor (Int64) -> Void) async throws -> URL {
        let delegate = DownloadProgress(progress: progress)
        var resumeData: Data?
        var attempt = 0
        while true {
            do {
                let result: (URL, URLResponse)
                if let resumeData {
                    result = try await session.download(resumeFrom: resumeData, delegate: delegate)
                } else {
                    result = try await session.download(from: url, delegate: delegate)
                }
                let (location, response) = result
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw DownloadError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                // The system deletes `location` when this returns; keep it.
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.moveItem(at: location, to: kept)
                return kept
            } catch let error as URLError where attempt < Self.maxRetries && Self.isTransient(error) {
                attempt += 1
                resumeData = error.downloadTaskResumeData
                try await Task.sleep(for: .seconds(Double(min(30, 1 << attempt))))
            }
        }
    }

    private static let maxRetries = 6

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
            true
        default:
            false
        }
    }

    private func verifyStaged() async throws {
        phase = .verifying(fraction: 0)
        let bad = await Self.mismatches(manifest.files, in: stagingDirectory) { [weak self] fraction in
            self?.phase = .verifying(fraction: fraction)
        }
        if !bad.isEmpty {
            for name in bad {
                try? FileManager.default.removeItem(at: stagingDirectory.appendingPathComponent(name))
            }
            throw DownloadError.checksum(bad)
        }
    }

    private func install() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: installDirectory.path) {
            try fm.removeItem(at: installDirectory)
        }
        try fm.moveItem(at: stagingDirectory, to: installDirectory)
    }

    // MARK: Hashing

    nonisolated static func mismatches(
        _ files: [ModelFile], in directory: URL, progress: @escaping @MainActor (Double) -> Void
    ) async -> [String] {
        await Task.detached(priority: .utility) {
            let total = max(1, files.reduce(0) { $0 + $1.size })
            var done: Int64 = 0
            var bad: [String] = []
            for file in files {
                let url = directory.appendingPathComponent(file.name)
                guard let handle = try? FileHandle(forReadingFrom: url) else {
                    bad.append(file.name)
                    continue
                }
                var hasher = SHA256()
                while true {
                    let chunk = (try? handle.read(upToCount: 8 << 20)) ?? nil
                    guard let chunk, !chunk.isEmpty else { break }
                    hasher.update(data: chunk)
                    done += Int64(chunk.count)
                    let fraction = Double(done) / Double(total)
                    await MainActor.run { progress(fraction) }
                }
                try? handle.close()
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                if digest != file.sha256 { bad.append(file.name) }
            }
            return bad
        }.value
    }

    enum DownloadError: Error {
        case http(Int)
        case checksum([String])
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DownloadError.http(let code): return "HTTP \(code)"
        case DownloadError.checksum(let names): return "checksum mismatch: " + names.joined(separator: ", ")
        default:
            let nsError = error as NSError
            return nsError.localizedDescription
        }
    }
}

/// Reports bytes received for one download task back to the main actor.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @MainActor (Int64) -> Void
    private var lastReport = Date.distantPast

    init(progress: @escaping @MainActor (Int64) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.1 else { return }
        lastReport = now
        let progress = self.progress
        Task { @MainActor in progress(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
