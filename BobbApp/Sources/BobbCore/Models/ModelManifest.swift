import Foundation

/// Qwen writes and Kev decides, each pinned to a commit and to the SHA-256
/// of every file, so the download is reproducible and verifiable: the app
/// fetches exactly these bytes or refuses them.
///
/// Hashes are Hugging Face's published LFS object ids for the large files
/// and were computed from the pinned revision for the small ones; see
/// `docs/ADR-010-local-kev-and-menu-bar-start.md`.
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
    public var sourceBaseURL: String? = nil

    /// The directory name the daemon resolves `id` to (`engine.resolve_local`).
    public var directoryName: String {
        String(id.split(separator: "/").last ?? Substring(id))
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public func url(for file: ModelFile) -> URL {
        if let sourceBaseURL { return URL(string: sourceBaseURL + "/" + file.name)! }
        return URL(string: "https://huggingface.co/\(id)/resolve/\(revision)/\(file.name)")!
    }

    public static let qwen35_4B = ModelManifest(
        id: "mlx-community/Qwen3.5-4B-4bit",
        revision: "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c",
        files: [
            ModelFile(name: "config.json", size: 3_366, sha256: "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa"),
            ModelFile(name: "chat_template.jinja", size: 7_756, sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
            ModelFile(name: "tokenizer.json", size: 19_989_343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
            ModelFile(name: "tokenizer_config.json", size: 1_139, sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
            ModelFile(name: "model.safetensors.index.json", size: 101_944, sha256: "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a"),
            ModelFile(name: "model.safetensors", size: 3_034_300_695, sha256: "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db"),
        ],
        license: "Apache-2.0",
        licenseURL: "https://www.apache.org/licenses/LICENSE-2.0"
    )

    public static let kev4B = ModelManifest(
        id: "RoderickQiu/kev-4b-mlx-8bit",
        revision: "6929ac37119fb11c2db74eb66b10a886c6d0dd3a",
        files: [
            ModelFile(name: "config.json", size: 2_752, sha256: "c981842962e7d010d2defc64676f6bdc3132ca4b34dcbbd111010b747d3358ad"),
            ModelFile(name: "tokenizer.json", size: 19_989_325, sha256: "06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523"),
            ModelFile(name: "tokenizer_config.json", size: 1_128, sha256: "8671bed7c852ce9e661be94f179a7b4ffd091c2a65aea0363e5501c20318ee45"),
            ModelFile(name: "special_tokens_map.json", size: 616, sha256: "6676f091c8bc4d1b50146427cfde92073402866b87b6e39223227931b70083e9"),
            ModelFile(name: "added_tokens.json", size: 707, sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"),
            ModelFile(name: "merges.txt", size: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
            ModelFile(name: "vocab.json", size: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            ModelFile(name: "provenance.json", size: 889, sha256: "457782224e3e1a460f819574b2b6d539c90c27001fa5ca95b49466cbd5bf44b3"),
            ModelFile(name: "LICENSE", size: 11_343, sha256: "50cbab8a892c5f2993b8c7351a99182507472def3b1374558308605d99b86b32"),
            ModelFile(name: "head.pt", size: 5_249_791, sha256: "dd633435998ecc751ac538717a3742e32149500fabf7d7276287dbf0693f347c"),
            ModelFile(name: "model.safetensors", size: 4_469_640_165, sha256: "83adf34ef8f2433166225960d0f074def35d3de52449fa8861bc356398312d31"),
        ],
        license: "Apache-2.0",
        licenseURL: "https://www.apache.org/licenses/LICENSE-2.0"
    )

    public static let `default` = qwen35_4B
    public static let decision = kev4B
    public static let voice = ModelManifest(
        id: "thewh1teagle/Kokoro-82M-ONNX", revision: "model-files-v1.0",
        files: [
            ModelFile(name: "kokoro-v1.0.int8.onnx", size: 92_361_271, sha256: "6e742170d309016e5891a994e1ce1559c702a2ccd0075e67ef7157974f6406cb"),
            ModelFile(name: "voices-v1.0.bin", size: 28_214_398, sha256: "bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d"),
        ], license: "Apache-2.0", licenseURL: "https://www.apache.org/licenses/LICENSE-2.0",
        sourceBaseURL: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
    )
    public static let required: [ModelManifest] = [qwen35_4B, kev4B, voice]
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
