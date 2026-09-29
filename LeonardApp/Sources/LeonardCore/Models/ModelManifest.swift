import Foundation

/// The one model Leonard ships with, pinned to a commit and to the SHA-256
/// of every file, so the download is reproducible and verifiable: the app
/// fetches exactly these bytes or refuses them.
///
/// Hashes are Hugging Face's published LFS object ids for the large files
/// and were computed from the pinned revision for the small ones; see
/// `docs/ADR-005-the-one-download.md`.
public struct ModelFile: Sendable, Equatable {
    public var name: String
    public var size: Int64
    public var sha256: String

    public init(name: String, size: Int64, sha256: String) {
        self.name = name
        self.size = size
        self.sha256 = sha256
    }
}

public struct ModelManifest: Sendable, Equatable {
    public var id: String
    public var revision: String
    public var files: [ModelFile]
    public var license: String
    public var licenseURL: String

    /// The directory name the daemon resolves `id` to (`engine.resolve_local`).
    public var directoryName: String {
        String(id.split(separator: "/").last ?? Substring(id))
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public func url(for file: ModelFile) -> URL {
        URL(string: "https://huggingface.co/\(id)/resolve/\(revision)/\(file.name)")!
    }

    public static let llama32_3B = ModelManifest(
        id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        revision: "7f0dc925e0d0afb0322d96f9255cfddf2ba5636e",
        files: [
            ModelFile(name: "config.json", size: 1122, sha256: "c546925585e48f43890d9dc5150df4fec73dd3780d92961c5ace451934cc4cd6"),
            ModelFile(name: "model.safetensors.index.json", size: 45720, sha256: "2ef31fa0b9dcda01f87835851d5e1d5a39ab6258ae618af6ea864c3747e556e4"),
            ModelFile(name: "special_tokens_map.json", size: 296, sha256: "6f38c73729248f6c127296386e3cdde96e254636cc58b4169d3fd32328d9a8ec"),
            ModelFile(name: "tokenizer_config.json", size: 54558, sha256: "022d5ae3df4737998ab97d8f31ac2bcb4c06dd8ebe5a8aba2b4aceef1e5ea7d3"),
            ModelFile(name: "tokenizer.json", size: 17_209_920, sha256: "6b9e4e7fb171f92fd137b777cc2714bf87d11576700a1dcd7a399e7bbe39537b"),
            ModelFile(name: "model.safetensors", size: 1_807_496_278, sha256: "d75e1ee0ea653cc5b76191ec934c7c0d568e94d4e47846619f1f4bc715b7b265"),
        ],
        license: "Llama 3.2 Community License",
        licenseURL: "https://www.llama.com/llama3_2/license/"
    )

    public static let `default` = llama32_3B
}

/// A cheap check (presence and size) that runs at every launch; the full
/// SHA-256 check runs after a download and on demand from Settings.
public enum ModelInstallation {
    public static func directory(for manifest: ModelManifest, in modelsDir: URL) -> URL {
        modelsDir.appendingPathComponent(manifest.directoryName, isDirectory: true)
    }

    public static func missingOrIncomplete(_ manifest: ModelManifest, in modelsDir: URL) -> [ModelFile] {
        let dir = directory(for: manifest, in: modelsDir)
        return manifest.files.filter { file in
            let path = dir.appendingPathComponent(file.name).path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber
            else { return true }
            return size.int64Value != file.size
        }
    }

    public static func isInstalled(_ manifest: ModelManifest, in modelsDir: URL) -> Bool {
        missingOrIncomplete(manifest, in: modelsDir).isEmpty
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
